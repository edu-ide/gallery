#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GalleryLiteRTLMBridge : NSObject
+ (BOOL)isCompiledWithLiteRTLM;
- (nullable NSString *)generateWithModelPath:(NSString *)modelPath
                                      prompt:(NSString *)prompt
                             attachmentsJson:(NSString *)attachmentsJson
                                enableVision:(BOOL)enableVision
                                  enableAudio:(BOOL)enableAudio
                                    cacheDir:(nullable NSString *)cacheDir
                            resetConversation:(BOOL)resetConversation
                                       error:(NSError **)error;
- (void)streamGenerateWithModelPath:(NSString *)modelPath
                              prompt:(NSString *)prompt
                     attachmentsJson:(NSString *)attachmentsJson
                        enableVision:(BOOL)enableVision
                          enableAudio:(BOOL)enableAudio
                            cacheDir:(nullable NSString *)cacheDir
                    resetConversation:(BOOL)resetConversation
                             onChunk:(void (^)(NSString *chunk))onChunk
                          onComplete:(void (^)(NSError * _Nullable error))onComplete;
@end

NS_ASSUME_NONNULL_END
