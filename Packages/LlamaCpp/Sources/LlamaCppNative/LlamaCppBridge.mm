#import "LlamaCppBridge.h"
#import <llama/llama.h>
#include <mutex>
#include <atomic>
#include <string>
#include <vector>
#include <stdexcept>
#include <algorithm>

namespace {
static std::once_flag g_llama_init_flag;

void ensure_llama_initialized() {
    std::call_once(g_llama_init_flag, []() {
        llama_backend_init();
    });
}

void set_bridge_error(NSError **error, const std::string &message) {
    if (error) {
        *error = [NSError errorWithDomain:@"LlamaCppBridge"
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: @(message.c_str())}];
    }
}
}

@implementation LlamaCppBridge {
    struct llama_model *_model;
    struct llama_context *_ctx;
    NSString *_modelPath;
    std::atomic<bool> _cancelled;
}

- (instancetype)init {
    if ((self = [super init])) {
        _model = nullptr;
        _ctx = nullptr;
        _modelPath = nil;
        _cancelled.store(false);
        ensure_llama_initialized();
    }
    return self;
}

- (void)dealloc {
    [self releaseModel];
}

- (void)cancel {
    _cancelled.store(true);
}

- (void)resetCancellation {
    _cancelled.store(false);
}

- (void)releaseModel {
    if (_ctx) {
        llama_free(_ctx);
        _ctx = nullptr;
    }
    if (_model) {
        llama_model_free(_model);
        _model = nullptr;
    }
    _modelPath = nil;
}

- (nullable NSDictionary *)prepareModel:(NSString *)path
                          contextLength:(int)contextLength
                                  error:(NSError **)error {
    try {
        if (_model && _ctx && [_modelPath isEqualToString:path]) {
            return @{
                @"path": _modelPath,
                @"n_ctx": @(llama_n_ctx(_ctx)),
                @"status": @"cached"
            };
        }

        [self releaseModel];

        ensure_llama_initialized();

        struct llama_model_params model_params = llama_model_default_params();
        model_params.n_gpu_layers = 99; // Offload all layers to Metal GPU

        struct llama_model *model = llama_model_load_from_file(path.UTF8String, model_params);
        if (!model) {
            throw std::runtime_error("LFM3 GGUFモデルの読み込みに失敗しました: " + std::string(path.UTF8String));
        }

        struct llama_context_params ctx_params = llama_context_default_params();
        ctx_params.n_ctx = contextLength > 0 ? (uint32_t)contextLength : 4096;
        ctx_params.n_batch = 512;
        ctx_params.n_ubatch = 512;
        ctx_params.n_threads = 4;
        ctx_params.n_threads_batch = 4;
        ctx_params.offload_kqv = true;

        struct llama_context *ctx = llama_init_from_model(model, ctx_params);
        if (!ctx) {
            llama_model_free(model);
            throw std::runtime_error("LFM3 推論コンテキストの初期化に失敗しました。");
        }

        _model = model;
        _ctx = ctx;
        _modelPath = [path copy];

        return @{
            @"path": _modelPath,
            @"n_ctx": @(llama_n_ctx(_ctx)),
            @"n_params": @(llama_model_n_params(_model)),
            @"status": @"ready"
        };
    } catch (const std::exception &e) {
        [self releaseModel];
        set_bridge_error(error, e.what());
        return nil;
    }
}

- (nullable NSString *)generateChatWithMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)messages
                                    temperature:(float)temperature
                                      maxTokens:(int)maxTokens
                                        onToken:(nullable void (^)(NSString *tokenPiece))onToken
                                          error:(NSError **)error {
    if (!_model || !_ctx) {
        set_bridge_error(error, "モデルがロードされていません。先に prepareModel を実行してください。");
        return nil;
    }

    _cancelled.store(false);

    try {
        const struct llama_vocab *vocab = llama_model_get_vocab(_model);
        if (!vocab) {
            throw std::runtime_error("モデルボキャブラリの取得に失敗しました。");
        }

        // LFM3-1.7B の ChatML フォーマットを構築。
        // 会話の応答速度を優先して思考を無効化する（公式テンプレートの enable_thinking=false 相当）
        std::string prompt = "<|startoftext|>";
        for (NSDictionary<NSString *, NSString *> *msg in messages) {
            NSString *role = msg[@"role"] ?: @"user";
            NSString *content = msg[@"content"] ?: @"";
            prompt += "<|im_start|>" + std::string(role.UTF8String) + "\n";
            if ([role isEqualToString:@"assistant"]) {
                prompt += "<think></think>";
            }
            prompt += std::string(content.UTF8String) + "<|im_end|>\n";
        }
        prompt += "<|im_start|>assistant\n<think></think>";

        // トークナイズ
        std::vector<llama_token> tokens(prompt.length() + 32);
        int32_t n_tokens = llama_tokenize(
            vocab,
            prompt.c_str(),
            (int32_t)prompt.length(),
            tokens.data(),
            (int32_t)tokens.size(),
            /*add_special=*/false, // プロンプト内に <|startoftext|> が既に含まれるため
            /*parse_special=*/true
        );

        if (n_tokens < 0) {
            tokens.resize(-n_tokens);
            n_tokens = llama_tokenize(
                vocab,
                prompt.c_str(),
                (int32_t)prompt.length(),
                tokens.data(),
                (int32_t)tokens.size(),
                false,
                true
            );
        }

        if (n_tokens <= 0) {
            throw std::runtime_error("プロンプトのトークナイズに失敗しました。");
        }
        tokens.resize(n_tokens);

        // 前回のセッションメモリ（KVキャッシュおよびリカレント/畳み込みステート）を完全にクリア
        llama_memory_clear(llama_get_memory(_ctx), true);

        // プロンプトをチャンク単位でデコード
        const int32_t batch_size = 512;
        struct llama_batch batch = llama_batch_init(batch_size, 0, 1);

        int32_t n_past = 0;
        for (int32_t i = 0; i < n_tokens; i += batch_size) {
            if (_cancelled.load()) {
                llama_batch_free(batch);
                throw std::runtime_error("生成がキャンセルされました。");
            }
            int32_t cur_batch = std::min(batch_size, n_tokens - i);
            batch.n_tokens = cur_batch;
            for (int32_t j = 0; j < cur_batch; ++j) {
                batch.token[j] = tokens[i + j];
                batch.pos[j] = n_past + j;
                batch.n_seq_id[j] = 1;
                batch.seq_id[j][0] = 0;
                batch.logits[j] = (i + j == n_tokens - 1) ? 1 : 0;
            }
            if (llama_decode(_ctx, batch) != 0) {
                llama_batch_free(batch);
                throw std::runtime_error("プロンプトのデコードに失敗しました。");
            }
            n_past += cur_batch;
        }

        // サンプラーチェーンの初期化 (LFM3 推奨パラメータ)
        struct llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
        struct llama_sampler *smpl = llama_sampler_chain_init(sparams);

        // 1. リピートペナルティ (1.1)
        llama_sampler_chain_add(smpl, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.1f, 0.0f, 0.0f));
        // 2. top_k (50)
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(50));

        float eff_temp = std::max(0.0f, temperature);
        if (eff_temp > 0.01f) {
            llama_sampler_chain_add(smpl, llama_sampler_init_temp(eff_temp));
            llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
        } else {
            llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
        }

        std::string generated_text;
        int max_gen = maxTokens > 0 ? maxTokens : 256;

        for (int step = 0; step < max_gen; ++step) {
            if (_cancelled.load()) {
                break;
            }

            llama_token new_token = llama_sampler_sample(smpl, _ctx, -1);
            if (llama_vocab_is_eog(vocab, new_token)) {
                break;
            }

            char piece_buf[128]{};
            int piece_len = llama_token_to_piece(vocab, new_token, piece_buf, sizeof(piece_buf), 0, false);
            if (piece_len > 0) {
                std::string piece(piece_buf, piece_len);
                generated_text += piece;

                // <|im_end|> 終端タグの検出
                if (generated_text.find("<|im_end|>") != std::string::npos) {
                    size_t pos = generated_text.find("<|im_end|>");
                    generated_text.erase(pos);
                    break;
                }

                if (onToken) {
                    NSString *pieceStr = [[NSString alloc] initWithBytes:piece.data()
                                                                 length:piece.size()
                                                               encoding:NSUTF8StringEncoding];
                    if (pieceStr) {
                        onToken(pieceStr);
                    }
                }
            }

            // 次のトークンをデコード
            batch.n_tokens = 1;
            batch.token[0] = new_token;
            batch.pos[0] = n_past++;
            batch.n_seq_id[0] = 1;
            batch.seq_id[0][0] = 0;
            batch.logits[0] = 1;

            if (llama_decode(_ctx, batch) != 0) {
                break;
            }
        }

        llama_batch_free(batch);
        llama_sampler_free(smpl);

        // 終端記号のクリーンアップ
        size_t end_tag_pos = generated_text.find("<|im_end|>");
        if (end_tag_pos != std::string::npos) {
            generated_text.erase(end_tag_pos);
        }
        // 思考を無効化しても出力された場合に備え、思考部分を返答から除く
        size_t think_end_pos = generated_text.rfind("</think>");
        if (think_end_pos != std::string::npos) {
            generated_text.erase(0, think_end_pos + std::string("</think>").size());
        }

        NSString *result = [[NSString alloc] initWithBytes:generated_text.data()
                                                    length:generated_text.size()
                                                  encoding:NSUTF8StringEncoding];
        if (!result) {
            result = [NSString stringWithCString:generated_text.c_str() encoding:NSISOLatin1StringEncoding];
        }

        return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    } catch (const std::exception &e) {
        set_bridge_error(error, e.what());
        return nil;
    }
}

@end
