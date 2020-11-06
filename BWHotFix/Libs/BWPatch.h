//
//  BWPatch.h
//  BWHotFix
//
//  Created by bairdweng on 2020/11/4.
//

#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface BWPatch : NSObject
+ (void)startEngine;
// 注入脚本
+ (JSValue *)evaluateScript:(NSString *)script;
@end


@interface JPBoxing : NSObject
@property (nonatomic) id obj;
@property (nonatomic) void *pointer;
@property (nonatomic) Class cls;
@property (nonatomic, weak) id weakObj;
@property (nonatomic, assign) id assignObj;
- (id)unbox;
- (void *)unboxPointer;
- (Class)unboxClass;
@end
NS_ASSUME_NONNULL_END
