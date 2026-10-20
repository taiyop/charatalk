#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LlamaCppBridge : NSObject

- (instancetype)init;
- (void)cancel;
- (void)resetCancellation;
- (void)releaseModel;

- (nullable NSDictionary *)prepareModel:(NSString *)path
                          contextLength:(int)contextLength
                                  error:(NSError **)error;

- (nullable NSString *)generateChatWithMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)messages
                                    temperature:(float)temperature
                                      maxTokens:(int)maxTokens
                                        onToken:(nullable void (^)(NSString *tokenPiece))onToken
                                          error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
