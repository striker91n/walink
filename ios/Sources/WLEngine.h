#import <Foundation/Foundation.h>

@interface WLEngine : NSObject

+ (instancetype)shared;

- (void)start;

/// Invoked on the main queue if the engine's loopback HTTP API never becomes ready.
@property (nonatomic, copy) void (^startupFailureHandler)(void);

- (void)stateWithCompletion:(void (^)(NSDictionary *state))completion;
- (void)pollEventsSince:(NSInteger)since completion:(void (^)(NSArray *events, NSError *error))completion;
- (void)sendText:(NSString *)text
           toJID:(NSString *)jid
      completion:(void (^)(BOOL ok, NSString *error))completion;
- (void)logoutWithCompletion:(void (^)(BOOL ok))completion;

@end
