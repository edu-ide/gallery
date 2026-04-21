#import "GalleryLiteRTLMBridge.h"

#if __has_include(<LiteRTLM/engine.h>)
#import <LiteRTLM/engine.h>
#define GALLERY_HAS_LITERTLM 1
#else
#define GALLERY_HAS_LITERTLM 0
#endif

static NSError *GalleryLiteRTLMError(NSString *message) {
  return [NSError errorWithDomain:@"GalleryLiteRTLMBridge"
                             code:-1
                         userInfo:@{NSLocalizedDescriptionKey: message}];
}

#if GALLERY_HAS_LITERTLM
static NSString *GalleryCaptureStderr(NSString *name, void (^block)(void)) {
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
  int savedStderr = dup(STDERR_FILENO);
  FILE *newErr = freopen([path UTF8String], "w+", stderr);
  (void)newErr;
  block();
  fflush(stderr);
  dup2(savedStderr, STDERR_FILENO);
  close(savedStderr);
  return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

static NSString *GalleryCollectTextFromJson(id node) {
  if ([node isKindOfClass:[NSString class]]) {
    return (NSString *)node;
  }
  if ([node isKindOfClass:[NSArray class]]) {
    NSMutableString *text = [NSMutableString string];
    for (id item in (NSArray *)node) {
      [text appendString:GalleryCollectTextFromJson(item)];
    }
    return text;
  }
  if ([node isKindOfClass:[NSDictionary class]]) {
    NSDictionary *dict = (NSDictionary *)node;
    id type = dict[@"type"];
    id text = dict[@"text"];
    if ([type isKindOfClass:[NSString class]] && [type isEqual:@"text"] && [text isKindOfClass:[NSString class]]) {
      return text;
    }
    id content = dict[@"content"];
    if (content) {
      return GalleryCollectTextFromJson(content);
    }
    if ([text isKindOfClass:[NSString class]]) {
      return text;
    }
  }
  return @"";
}

static NSString *GalleryExtractText(NSString *json) {
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  if (!data) return json;
  id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (!parsed) return json;
  NSString *text = GalleryCollectTextFromJson(parsed);
  return text.length > 0 ? text : json;
}

static LiteRtLmEngine *GallerySharedEngine = NULL;
static LiteRtLmConversation *GallerySharedConversation = NULL;
static NSString *GallerySharedModelPath = nil;

static void GalleryResetSharedRuntime(void) {
  if (GallerySharedConversation) {
    litert_lm_conversation_delete(GallerySharedConversation);
    GallerySharedConversation = NULL;
  }
  if (GallerySharedEngine) {
    litert_lm_engine_delete(GallerySharedEngine);
    GallerySharedEngine = NULL;
  }
  GallerySharedModelPath = nil;
}
#endif

@implementation GalleryLiteRTLMBridge

+ (BOOL)isCompiledWithLiteRTLM {
  return GALLERY_HAS_LITERTLM != 0;
}

- (NSString *)generateWithModelPath:(NSString *)modelPath
                             prompt:(NSString *)prompt
                           cacheDir:(NSString *)cacheDir
                              error:(NSError **)error {
#if !GALLERY_HAS_LITERTLM
  if (error) {
    *error = GalleryLiteRTLMError(@"LiteRT-LM headers/framework are not linked in this build.");
  }
  return nil;
#else
  if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
    if (error) *error = GalleryLiteRTLMError([NSString stringWithFormat:@"Model file not found: %@", modelPath]);
    return nil;
  }

  litert_lm_set_min_log_level(2);

  @synchronized([GalleryLiteRTLMBridge class]) {
    if (!GallerySharedEngine || !GallerySharedConversation || ![GallerySharedModelPath isEqualToString:modelPath]) {
      GalleryResetSharedRuntime();

      LiteRtLmEngineSettings *settings = litert_lm_engine_settings_create(
          [modelPath UTF8String], "cpu", NULL, NULL);
      if (!settings) {
        if (error) *error = GalleryLiteRTLMError(@"litert_lm_engine_settings_create returned NULL");
        return nil;
      }
      if (cacheDir.length > 0) {
        litert_lm_engine_settings_set_cache_dir(settings, [cacheDir UTF8String]);
      }

      __block LiteRtLmEngine *engine = NULL;
      NSString *engineLogs = GalleryCaptureStderr(@"gallery_litert_engine.log", ^{
        engine = litert_lm_engine_create(settings);
      });
      litert_lm_engine_settings_delete(settings);
      if (!engine) {
        if (error) *error = GalleryLiteRTLMError([NSString stringWithFormat:@"litert_lm_engine_create returned NULL.%@%@",
          engineLogs.length ? @"\nNative log:\n" : @"", engineLogs]);
        return nil;
      }

      __block LiteRtLmConversationConfig *conversationConfig = NULL;
      __block LiteRtLmConversation *conversation = NULL;
      NSString *conversationLogs = GalleryCaptureStderr(@"gallery_litert_conversation.log", ^{
        conversationConfig = litert_lm_conversation_config_create(engine, NULL, NULL, NULL, NULL, false);
        conversation = litert_lm_conversation_create(engine, conversationConfig);
      });
      if (conversationConfig) litert_lm_conversation_config_delete(conversationConfig);
      if (!conversation) {
        litert_lm_engine_delete(engine);
        if (error) *error = GalleryLiteRTLMError([NSString stringWithFormat:@"litert_lm_conversation_create returned NULL.%@%@",
          conversationLogs.length ? @"\nNative log:\n" : @"", conversationLogs]);
        return nil;
      }

      GallerySharedEngine = engine;
      GallerySharedConversation = conversation;
      GallerySharedModelPath = [modelPath copy];
    }

    NSDictionary *message = @{ @"role": @"user", @"content": prompt ?: @"" };
    NSData *messageData = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    NSString *messageJson = [[NSString alloc] initWithData:messageData encoding:NSUTF8StringEncoding] ?: @"{\"role\":\"user\",\"content\":\"\"}";

    LiteRtLmJsonResponse *response = litert_lm_conversation_send_message(GallerySharedConversation, [messageJson UTF8String], NULL);
    if (!response) {
      if (error) *error = GalleryLiteRTLMError(@"litert_lm_conversation_send_message returned NULL");
      return nil;
    }

    const char *raw = litert_lm_json_response_get_string(response);
    NSString *responseJson = raw ? [NSString stringWithUTF8String:raw] : @"";
    litert_lm_json_response_delete(response);

    return GalleryExtractText(responseJson);
  }
#endif
}

@end
