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
static BOOL GallerySharedVisionBackend = NO;
static BOOL GallerySharedAudioBackend = NO;

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
  GallerySharedVisionBackend = NO;
  GallerySharedAudioBackend = NO;
}

static BOOL GalleryEnsureConversation(
    NSString *modelPath,
    BOOL enableVision,
    BOOL enableAudio,
    NSString *cacheDir,
    NSError **error) {
  if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
    if (error) *error = GalleryLiteRTLMError([NSString stringWithFormat:@"Model file not found: %@", modelPath]);
    return NO;
  }

  litert_lm_set_min_log_level(2);

  if (GallerySharedEngine &&
      GallerySharedConversation &&
      [GallerySharedModelPath isEqualToString:modelPath] &&
      GallerySharedVisionBackend == enableVision &&
      GallerySharedAudioBackend == enableAudio) {
    return YES;
  }

  GalleryResetSharedRuntime();

  const char *visionBackend = enableVision ? "cpu" : NULL;
  const char *audioBackend = enableAudio ? "cpu" : NULL;
  LiteRtLmEngineSettings *settings = litert_lm_engine_settings_create(
      [modelPath UTF8String], "cpu", visionBackend, audioBackend);
  if (!settings) {
    if (error) *error = GalleryLiteRTLMError(@"litert_lm_engine_settings_create returned NULL");
    return NO;
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
    return NO;
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
    return NO;
  }

  GallerySharedEngine = engine;
  GallerySharedConversation = conversation;
  GallerySharedModelPath = [modelPath copy];
  GallerySharedVisionBackend = enableVision;
  GallerySharedAudioBackend = enableAudio;
  return YES;
}

static NSArray *GalleryAttachmentPartsFromJson(NSString *attachmentsJson) {
  if (attachmentsJson.length == 0) return @[];
  NSData *data = [attachmentsJson dataUsingEncoding:NSUTF8StringEncoding];
  if (!data) return @[];

  id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![parsed isKindOfClass:[NSArray class]]) return @[];

  NSMutableArray *parts = [NSMutableArray array];
  for (id item in (NSArray *)parsed) {
    if (![item isKindOfClass:[NSDictionary class]]) continue;
    NSDictionary *attachment = (NSDictionary *)item;
    id kind = attachment[@"kind"];
    id path = attachment[@"path"];
    if (![kind isKindOfClass:[NSString class]] || ![path isKindOfClass:[NSString class]]) continue;
    if (![(NSString *)kind isEqualToString:@"image"] && ![(NSString *)kind isEqualToString:@"audio"]) continue;
    if (![[NSFileManager defaultManager] fileExistsAtPath:(NSString *)path]) continue;
    [parts addObject:@{ @"type": kind, @"path": path }];
  }
  return parts;
}

static NSString *GalleryBuildUserMessageJson(NSString *prompt, NSString *attachmentsJson) {
  NSMutableArray *parts = [NSMutableArray array];
  if (prompt.length > 0) {
    [parts addObject:@{ @"type": @"text", @"text": prompt }];
  }
  [parts addObjectsFromArray:GalleryAttachmentPartsFromJson(attachmentsJson)];

  id content = prompt ?: @"";
  if (parts.count > 1) {
    content = parts;
  } else if (parts.count == 1) {
    NSDictionary *onlyPart = (NSDictionary *)parts.firstObject;
    if ([[onlyPart objectForKey:@"type"] isEqualToString:@"text"]) {
      content = [onlyPart objectForKey:@"text"] ?: @"";
    } else {
      content = parts;
    }
  }

  NSDictionary *message = @{ @"role": @"user", @"content": content };
  NSData *messageData = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
  return [[NSString alloc] initWithData:messageData encoding:NSUTF8StringEncoding] ?: @"{\"role\":\"user\",\"content\":\"\"}";
}

struct GalleryStreamContext {
  void (^onChunk)(NSString *);
  void (^onComplete)(NSError *);
  BOOL completed;
};

static void GalleryStreamCallback(void *callbackData, const char *chunk, bool isFinal, const char *errorMessage) {
  GalleryStreamContext *context = (GalleryStreamContext *)callbackData;
  if (!context || context->completed) return;

  if (errorMessage) {
    context->completed = YES;
    NSError *error = GalleryLiteRTLMError([NSString stringWithUTF8String:errorMessage]);
    if (context->onComplete) context->onComplete(error);
    delete context;
    return;
  }

  if (chunk && context->onChunk) {
    NSString *rawChunk = [NSString stringWithUTF8String:chunk];
    NSString *text = GalleryExtractText(rawChunk);
    if (text.length > 0) {
      context->onChunk(text);
    }
  }

  if (isFinal) {
    context->completed = YES;
    if (context->onComplete) context->onComplete(nil);
    delete context;
  }
}
#endif

@implementation GalleryLiteRTLMBridge

+ (BOOL)isCompiledWithLiteRTLM {
  return GALLERY_HAS_LITERTLM != 0;
}

- (NSString *)generateWithModelPath:(NSString *)modelPath
                             prompt:(NSString *)prompt
                    attachmentsJson:(NSString *)attachmentsJson
                       enableVision:(BOOL)enableVision
                         enableAudio:(BOOL)enableAudio
                           cacheDir:(NSString *)cacheDir
                              error:(NSError **)error {
#if !GALLERY_HAS_LITERTLM
  if (error) {
    *error = GalleryLiteRTLMError(@"LiteRT-LM headers/framework are not linked in this build.");
  }
  return nil;
#else
  @synchronized([GalleryLiteRTLMBridge class]) {
    if (!GalleryEnsureConversation(modelPath, enableVision, enableAudio, cacheDir, error)) return nil;
    NSString *messageJson = GalleryBuildUserMessageJson(prompt, attachmentsJson);

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

- (void)streamGenerateWithModelPath:(NSString *)modelPath
                              prompt:(NSString *)prompt
                     attachmentsJson:(NSString *)attachmentsJson
                        enableVision:(BOOL)enableVision
                          enableAudio:(BOOL)enableAudio
                            cacheDir:(NSString *)cacheDir
                             onChunk:(void (^)(NSString *chunk))onChunk
                          onComplete:(void (^)(NSError * _Nullable error))onComplete {
#if !GALLERY_HAS_LITERTLM
  if (onComplete) {
    onComplete(GalleryLiteRTLMError(@"LiteRT-LM headers/framework are not linked in this build."));
  }
#else
  @synchronized([GalleryLiteRTLMBridge class]) {
    NSError *prepareError = nil;
    if (!GalleryEnsureConversation(modelPath, enableVision, enableAudio, cacheDir, &prepareError)) {
      if (onComplete) onComplete(prepareError);
      return;
    }

    NSString *messageJson = GalleryBuildUserMessageJson(prompt, attachmentsJson);
    GalleryStreamContext *context = new GalleryStreamContext();
    context->onChunk = [onChunk copy];
    context->onComplete = [onComplete copy];
    context->completed = NO;

    int rc = litert_lm_conversation_send_message_stream(
      GallerySharedConversation,
      [messageJson UTF8String],
      NULL,
      &GalleryStreamCallback,
      context
    );
    if (rc != 0) {
      NSError *error = GalleryLiteRTLMError([NSString stringWithFormat:@"litert_lm_conversation_send_message_stream failed rc=%d", rc]);
      if (context->onComplete) context->onComplete(error);
      delete context;
    }
  }
#endif
}

@end
