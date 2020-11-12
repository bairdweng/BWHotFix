//
//  ExampleRuntime.m
//  BWHotFix
//
//  Created by bairdweng on 2020/11/9.
//

#import "ExampleRuntime.h"

@interface ExampleRuntime()

@end
@implementation ExampleRuntime
- (instancetype)init
{
    self = [super init];
    if (self) {
        
    }
    return self;
}

- (void)pushRuntimeVc:(UIViewController *)target {
    // 创建一个视图控制器
    const char *className;
    className = [@"TestViewController2" UTF8String];
    Class kclass = objc_getClass(className);
    if (!kclass) {
        Class cls = objc_allocateClassPair([UIViewController class], className, 0);
        // 注册元类
        objc_registerClassPair(cls);
        // 获取方法名
        SEL selector = NSSelectorFromString(@"presentViewController:animated:completion");
        IMP imp = [target methodForSelector:selector];

//        [target presentViewController:cls animated:YES completion:nil];
    }
  
}

@end
