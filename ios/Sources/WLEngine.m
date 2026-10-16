#import "WLEngine.h"

#include <stdlib.h>
#include <unistd.h>

// nodejs-mobile exposes exactly one C entry point in NodeMobile.framework.
extern int node_start(int argc, char *argv[]);

static NSString * const WLEngineBaseURL = @"http://127.0.0.1:8787";

@interface WLEngine ()

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) dispatch_queue_t requestQueue;
@property (nonatomic, assign) BOOL started;

@end

@implementation WLEngine

+ (instancetype)shared
{
    static WLEngine *sharedEngine = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedEngine = [[self alloc] init];
    });
    return sharedEngine;
}

- (instancetype)init
{
    self = [super init];
    if (!self) return nil;

    _requestQueue = dispatch_queue_create("com.striker91n.walink.engine", DISPATCH_QUEUE_SERIAL);

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 35.0;
    configuration.timeoutIntervalForResource = 300.0;
    _session = [NSURLSession sessionWithConfiguration:configuration];

    return self;
}

#pragma mark - Boot

- (void)start
{
    if (self.started) return;
    self.started = YES;

    // Start the Node runtime on its own thread; node_start blocks forever.
    [NSThread detachNewThreadSelector:@selector(nodeThread)
                             toTarget:self
                           withObject:nil];

    // Wait for the loopback HTTP server to come up.
    dispatch_async(self.requestQueue, ^{
        [self waitForReady];
    });
}

- (void)nodeThread
{
    @autoreleasepool {
        NSArray *documentPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                      NSUserDomainMask,
                                                                      YES);
        NSString *documentsDirectory = documentPaths.firstObject;
        NSString *dataDirectory = [documentsDirectory stringByAppendingPathComponent:@".walink"];

        [[NSFileManager defaultManager] createDirectoryAtPath:dataDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        setenv("WALINK_PORT", "8787", 1);
        setenv("WALINK_DATA_DIR", dataDirectory.UTF8String, 1);
        chdir(documentsDirectory.UTF8String);

        NSString *enginePath = [[NSBundle mainBundle] pathForResource:@"main"
                                                               ofType:@"js"
                                                          inDirectory:@"engine"];
        if (!enginePath) {
            NSLog(@"[WLEngine] engine/main.js not found in bundle");
            return;
        }

        char *argv[] = {
            strdup("node"),
            strdup(enginePath.UTF8String),
            NULL
        };

        node_start(2, argv);

        free(argv[0]);
        free(argv[1]);
    }
}

- (void)waitForReady
{
    NSURL *url = [NSURL URLWithString:[WLEngineBaseURL stringByAppendingString:@"/api/health"]];

    for (NSInteger attempt = 0; attempt < 120; attempt++) {
        __block BOOL ready = NO;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

        NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
                                                 completionHandler:^(NSData *data,
                                                                     NSURLResponse *response,
                                                                     NSError *error) {
            if (!error && [(NSHTTPURLResponse *)response statusCode] == 200) {
                ready = YES;
            }
            dispatch_semaphore_signal(semaphore);
        }];
        [task resume];

        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));

        if (ready) {
            NSLog(@"[WLEngine] engine health check passed");
            return;
        }

        [NSThread sleepForTimeInterval:0.5];
    }

    NSLog(@"[WLEngine] engine did not become ready in time");
}

#pragma mark - API helpers

- (void)handleResponseData:(NSData *)data
                  response:(NSURLResponse *)response
                     error:(NSError *)error
                completion:(void (^)(id json, NSError *requestError))completion
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
            completion(nil, error);
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = httpResponse.statusCode;
        if (statusCode < 200 || statusCode >= 300) {
            NSString *message = [NSString stringWithFormat:@"HTTP %ld", (long)statusCode];
            NSError *statusError = [NSError errorWithDomain:@"WLEngine"
                                                       code:statusCode
                                                   userInfo:@{NSLocalizedDescriptionKey: message}];
            completion(nil, statusError);
            return;
        }

        if (!data || data.length == 0) {
            completion(nil, nil);
            return;
        }

        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data
                                                  options:0
                                                    error:&jsonError];
        completion(json, jsonError);
    });
}

- (void)GET:(NSString *)path completion:(void (^)(id json, NSError *error))completion
{
    dispatch_async(self.requestQueue, ^{
        NSURL *url = [NSURL URLWithString:[WLEngineBaseURL stringByAppendingString:path]];
        NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
                                                 completionHandler:^(NSData *data,
                                                                     NSURLResponse *response,
                                                                     NSError *error) {
            [self handleResponseData:data response:response error:error completion:completion];
        }];
        [task resume];
    });
}

- (void)POST:(NSString *)path
        body:(NSDictionary *)body
  completion:(void (^)(BOOL ok, NSString *error))completion
{
    dispatch_async(self.requestQueue, ^{
        NSURL *url = [NSURL URLWithString:[WLEngineBaseURL stringByAppendingString:path]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:15.0];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

        if (body) {
            NSError *jsonError = nil;
            NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body
                                                               options:0
                                                                 error:&jsonError];
            if (!jsonError) {
                request.HTTPBody = bodyData;
            }
        }

        NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                     completionHandler:^(NSData *data,
                                                                         NSURLResponse *response,
                                                                         NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
                BOOL ok = !error && statusCode >= 200 && statusCode < 300;
                completion(ok, error.localizedDescription);
            });
        }];
        [task resume];
    });
}

#pragma mark - Public API

- (void)stateWithCompletion:(void (^)(NSDictionary *state))completion
{
    [self GET:@"/api/state" completion:^(id json, NSError *error) {
        if ([json isKindOfClass:[NSDictionary class]]) {
            completion(json);
        } else {
            completion(nil);
        }
    }];
}

- (void)pollEventsSince:(NSInteger)since completion:(void (^)(NSArray *events))completion
{
    dispatch_async(self.requestQueue, ^{
        NSString *path = [NSString stringWithFormat:@"/api/events?since=%ld", (long)since];
        NSURL *url = [NSURL URLWithString:[WLEngineBaseURL stringByAppendingString:path]];

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:30.0];

        NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                     completionHandler:^(NSData *data,
                                                                         NSURLResponse *response,
                                                                         NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    completion(@[]);
                    return;
                }

                NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
                if (statusCode < 200 || statusCode >= 300) {
                    completion(@[]);
                    return;
                }

                NSError *jsonError = nil;
                id json = [NSJSONSerialization JSONObjectWithData:data
                                                          options:0
                                                            error:&jsonError];
                if ([json isKindOfClass:[NSArray class]]) {
                    completion(json);
                } else {
                    completion(@[]);
                }
            });
        }];
        [task resume];
    });
}

- (void)sendText:(NSString *)text
           toJID:(NSString *)jid
      completion:(void (^)(BOOL ok, NSString *error))completion
{
    NSDictionary *body = @{
        @"jid": jid ?: @"",
        @"text": text ?: @""
    };
    [self POST:@"/api/send" body:body completion:completion];
}

- (void)logoutWithCompletion:(void (^)(BOOL ok))completion
{
    [self POST:@"/api/logout" body:nil completion:^(BOOL ok, NSString *error) {
        completion(ok);
    }];
}

@end
