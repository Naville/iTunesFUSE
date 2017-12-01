#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
@interface iTunesFuse:NSObject
+(void)load;
- (void)handleDrive:(NSNotification *)notification;
- (void)didUnmount:(NSNotification*)notification;
- (void)didMount:(NSNotification *)notification;
@end
