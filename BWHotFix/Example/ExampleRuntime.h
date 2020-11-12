//
//  ExampleRuntime.h
//  BWHotFix
//
//  Created by bairdweng on 2020/11/9.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN

@interface ExampleRuntime : NSObject
- (void)pushRuntimeVc:(UIViewController *)target;
@end

NS_ASSUME_NONNULL_END
