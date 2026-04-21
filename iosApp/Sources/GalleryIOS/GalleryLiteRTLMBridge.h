#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GalleryLiteRTLMBridge : NSObject
+ (BOOL)isCompiledWithLiteRTLM;
- (nullable NSString *)generateWithModelPath:(NSString *)modelPath
                                      prompt:(NSString *)prompt
                                    cacheDir:(nullable NSString *)cacheDir
                                       error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
