#import <Foundation/Foundation.h>

@interface WLEngine : NSObject

+ (instancetype)shared;

- (void)start;

- (void)stateWithCompletion:(void (^)(NSDictionary *state))completion;
- (void)pollEventsSince:(NSInteger)since completion:(void (^)(NSArray *events))completion;
- (void)sendText:(NSString *)text
           toJID:(NSString *)jid
      completion:(void (^)(BOOL ok, NSString *error))completion;
- (void)logoutWithCompletion:(void (^)(BOOL ok))completion;

@end
