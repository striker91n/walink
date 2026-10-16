#import "WLAppDelegate.h"
#import "WLHomeViewController.h"
#import "WLEngine.h"

@implementation WLAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

    WLHomeViewController *homeViewController = [[WLHomeViewController alloc] init];
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:homeViewController];

    self.window.rootViewController = navigationController;
    [self.window makeKeyAndVisible];

    [[WLEngine shared] start];

    return YES;
}

@end
