//
//  BWPatch.m
//  BWHotFix
//
//  Created by bairdweng on 2020/11/4.
//

#import "BWPatch.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <UIKit/UIKit.h>
// 消除警告
#pragma GCC diagnostic ignored "-Wundeclared-selector"

#pragma mark --静态变量区

#ifdef DEBUG
static NSArray *_JSLastCallStack;
#endif
static JSContext *_context;
static NSMutableDictionary *_propKeys;
static JSContext *_context;
static NSString *_regexStr = @"(?<!\\\\)\\.\\s*(\\w+)\\s*\\(";
static NSString *_replaceStr = @".__c(\"$1\")(";
static NSRegularExpression* _regex;
static NSObject *_nullObj;
static NSObject *_nilObj;
static NSMutableDictionary *_registeredStruct;
static NSMutableDictionary *_currInvokeSuperClsName;
static char *kPropAssociatedObjectKey;
static BOOL _autoConvert;
static BOOL _convertOCNumberToString;
static NSString *_scriptRootDir;
static NSMutableSet *_runnedScript;

static NSMutableDictionary *_JSOverideMethods;
static NSMutableDictionary *_TMPMemoryPool;
static NSMutableDictionary *_propKeys;
static NSMutableDictionary *_JSMethodSignatureCache;
static NSLock              *_JSMethodSignatureLock;
static NSRecursiveLock     *_JSMethodForwardCallLock;
static NSMutableDictionary *_protocolTypeEncodeDict;
static NSMutableArray      *_pointersToRelease;






#pragma mark - JPFix
typedef struct {double d;} JPDouble;
typedef struct {float f;} JPFloat;
static NSMethodSignature *fixSignature(NSMethodSignature *signature)
{
#if TARGET_OS_IPHONE
#ifdef __LP64__
    if (!signature) {
        return nil;
    }
    
    if ([[UIDevice currentDevice].systemVersion floatValue] < 7.09) {
        BOOL isReturnDouble = (strcmp([signature methodReturnType], "d") == 0);
        BOOL isReturnFloat = (strcmp([signature methodReturnType], "f") == 0);

        if (isReturnDouble || isReturnFloat) {
            NSMutableString *types = [NSMutableString stringWithFormat:@"%s@:", isReturnDouble ? @encode(JPDouble) : @encode(JPFloat)];
            for (int i = 2; i < signature.numberOfArguments; i++) {
                const char *argType = [signature getArgumentTypeAtIndex:i];
                [types appendFormat:@"%s", argType];
            }
            signature = [NSMethodSignature signatureWithObjCTypes:[types UTF8String]];
        }
    }
#endif
#endif
    return signature;
}

@interface NSObject (JPFix)
- (NSMethodSignature *)jp_methodSignatureForSelector:(SEL)aSelector;
+ (void)jp_fixMethodSignature;
@end

@implementation NSObject (JPFix)
const static void *JPFixedFlagKey = &JPFixedFlagKey;
- (NSMethodSignature *)jp_methodSignatureForSelector:(SEL)aSelector
{
    NSMethodSignature *signature = [self jp_methodSignatureForSelector:aSelector];
    return fixSignature(signature);
}
+ (void)jp_fixMethodSignature
{
#if TARGET_OS_IPHONE
#ifdef __LP64__
    if ([[UIDevice currentDevice].systemVersion floatValue] < 7.1) {
        NSNumber *flag = objc_getAssociatedObject(self, JPFixedFlagKey);
        if (!flag.boolValue) {
            SEL originalSelector = @selector(methodSignatureForSelector:);
            SEL swizzledSelector = @selector(jp_methodSignatureForSelector:);
            Method originalMethod = class_getInstanceMethod(self, originalSelector);
            Method swizzledMethod = class_getInstanceMethod(self, swizzledSelector);
            BOOL didAddMethod = class_addMethod(self, originalSelector, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod));
            if (didAddMethod) {
                class_replaceMethod(self, swizzledSelector, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod));
            } else {
                method_exchangeImplementations(originalMethod, swizzledMethod);
            }
            objc_setAssociatedObject(self, JPFixedFlagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
#endif
#endif
}
@end




#pragma mark - JPBoxing
@implementation JPBoxing

#define JPBOXING_GEN(_name, _prop, _type) \
+ (instancetype)_name:(_type)obj  \
{   \
    JPBoxing *boxing = [[JPBoxing alloc] init]; \
    boxing._prop = obj;   \
    return boxing;  \
}

JPBOXING_GEN(boxObj, obj, id)
JPBOXING_GEN(boxPointer, pointer, void *)
JPBOXING_GEN(boxClass, cls, Class)
JPBOXING_GEN(boxWeakObj, weakObj, id)
JPBOXING_GEN(boxAssignObj, assignObj, id)

- (id)unbox
{
    if (self.obj) return self.obj;
    if (self.weakObj) return self.weakObj;
    if (self.assignObj) return self.assignObj;
    if (self.cls) return self.cls;
    return self;
}
- (void *)unboxPointer
{
    return self.pointer;
}
- (Class)unboxClass
{
    return self.cls;
}
@end




@implementation BWPatch

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"


#pragma mark - 工具类
// 将 OC 对象转为 js formatOCToJS
static id formatOCToJS(id obj){
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSDictionary class]] || [obj isKindOfClass:[NSArray class]] || [obj isKindOfClass:[NSDate class]]) {
        return _autoConvert ? obj: _wrapObj([JPBoxing boxObj:obj]);
    }
    if ([obj isKindOfClass:[NSNumber class]]) {
        return _convertOCNumberToString ? [(NSNumber*)obj stringValue] : obj;
    }
    if ([obj isKindOfClass:NSClassFromString(@"NSBlock")] || [obj isKindOfClass:[JSValue class]]) {
        return obj;
    }
    return _wrapObj(obj);
}
// 把 oc 对象转为 js 对象 （增加了 __obj __clsName 等字段）
static NSDictionary *_wrapObj(id obj){
    if (!obj || obj == _nilObj) {
        return @{@"__isNil": @(YES)};
    }
    return @{@"__obj": obj, @"__clsName": NSStringFromClass([obj isKindOfClass:[JPBoxing class]] ? [[((JPBoxing *)obj) unbox] class]: [obj class])};
}

static void (^_exceptionBlock)(NSString *log) = ^void(NSString *log) {
    
    NSLog(@"log===%@",log);
//    NSCAssert(NO, log);
};
static const void *propKey(NSString *propName) {
    if (!_propKeys) _propKeys = [[NSMutableDictionary alloc] init];
    id key = _propKeys[propName];
    if (!key) {
        key = [propName copy];
        [_propKeys setObject:key forKey:propName];
    }
    return (__bridge const void *)(key);
}
static id getPropIMP(id slf, SEL selector, NSString *propName) {
    return objc_getAssociatedObject(slf, propKey(propName));
}
static void setPropIMP(id slf, SEL selector, id val, NSString *propName) {
    objc_setAssociatedObject(slf, propKey(propName), val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static NSString *trim(NSString *string) {
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL blockTypeIsObject(NSString *typeString) {
    return [typeString rangeOfString:@"*"].location != NSNotFound || [typeString isEqualToString:@"id"];
}

static BOOL blockTypeIsScalarPointer(NSString *typeString) {
    NSUInteger location = [typeString rangeOfString:@"*"].location;
    NSString *typeWithoutAsterisk = trim([typeString stringByReplacingOccurrencesOfString:@"*" withString:@""]);
    
    return (location == typeString.length-1 &&
            !NSClassFromString(typeWithoutAsterisk));
}
static NSString *convertJPSelectorString(NSString *selectorString) {
    // 用 - 代替 __
    NSString *tmpJSMethodName = [selectorString stringByReplacingOccurrencesOfString:@"__" withString:@"-"];
    // 用 ： 代替 _
    NSString *selectorName = [tmpJSMethodName stringByReplacingOccurrencesOfString:@"_" withString:@":"];
    // 用 _ 代替 -
    return [selectorName stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
}

// 获取 protocol 中相应方法的函数签名
static char *methodTypesInProtocol(NSString *protocolName, NSString *selectorName, BOOL isInstanceMethod, BOOL isRequired) {
    // 获取 protocol
    Protocol *protocol = objc_getProtocol([trim(protocolName) cStringUsingEncoding:NSUTF8StringEncoding]);
    unsigned int selCount = 0;
    // 复制 protocol 的方法列表
    struct objc_method_description *methods = protocol_copyMethodDescriptionList(protocol, isRequired, isInstanceMethod, &selCount);
    for (int i = 0; i < selCount; i ++) {
        // 遍历 protocol 的方法列表，找到和目标方法同名的方法，然后通过 c 方法复制出来返回。否则返回 NULL
        if ([selectorName isEqualToString:NSStringFromSelector(methods[i].name)]) {
            char *types = malloc(strlen(methods[i].types) + 1);
            strcpy(types, methods[i].types);
            free(methods);
            return types;
        }
    }
    free(methods);
    return NULL;
}




# pragma mark -入口
+ (void)startEngine {
    if (![JSContext class] || _context) {
        return;
    }
    JSContext *context = [[JSContext alloc] init];
    // 定义方法
    context[@"_OC_defineClass"] = ^(NSString *classDeclaration, JSValue *instanceMethods, JSValue *classMethods) {
        return defineClass(classDeclaration, instanceMethods, classMethods);
    };
    // null的处理
    context[@"_OC_null"] = formatOCToJS(_nullObj);
    // 捕捉异常
    context[@"_OC_catch"] = ^(JSValue *msg, JSValue *stack) {
        _exceptionBlock([NSString stringWithFormat:@"js exception, \nmsg: %@, \nstack: \n %@", [msg toObject], [stack toObject]]);
    };
    
    // 获取传入类的父类名
    context[@"_OC_superClsName"] = ^(NSString *clsName) {
        Class cls = NSClassFromString(clsName);
        return NSStringFromClass([cls superclass]);
    };
    // 实例方法
    context[@"_OC_callI"] = ^id(JSValue *obj, NSString *selectorName, JSValue *arguments, BOOL isSuper) {
        return callSelector(nil, selectorName, arguments, obj, isSuper);
    };
    // 类方法
    context[@"_OC_callC"] = ^id(NSString *className, NSString *selectorName, JSValue *arguments) {
        return callSelector(className, selectorName, arguments, nil, NO);
    };
    // js 调用 oc 方法，打印 js 对象到 oc 控制台
    context[@"_OC_log"] = ^() {
        NSArray *args = [JSContext currentArguments];
        for (JSValue *jsVal in args) {
            id obj = formatJSToOC(jsVal);
            NSLog(@"JSPatch.log: %@", obj == _nilObj ? nil : (obj == _nullObj ? [NSNull null]: obj));
        }
    };
    _context = context;
    _nilObj = [[NSObject alloc] init];
    _JSMethodSignatureLock = [[NSLock alloc] init];
    _JSMethodForwardCallLock = [[NSRecursiveLock alloc] init];
    _registeredStruct = [[NSMutableDictionary alloc] init];
    _currInvokeSuperClsName = [[NSMutableDictionary alloc] init];
    // 注入脚本
    NSString *path = [[NSBundle bundleForClass:[self class]] pathForResource:@"JSPatch" ofType:@"js"];
    if (!path) _exceptionBlock(@"can't find JSPatch.js");
    NSString *jsCore = [[NSString alloc] initWithData:[[NSFileManager defaultManager] contentsAtPath:path] encoding:NSUTF8StringEncoding];
    if ([_context respondsToSelector:@selector(evaluateScript:withSourceURL:)]) {
        [_context evaluateScript:jsCore withSourceURL:[NSURL URLWithString:@"JSPatch.js"]];
    } else {
        [_context evaluateScript:jsCore];
    }
}
+ (JSValue *)evaluateScript:(NSString *)script {
    return [self _evaluateScript:script withSourceURL:[NSURL URLWithString:@"main.js"]];
}
+ (JSValue *)_evaluateScriptWithPath:(NSString *)filePath{
    NSString *script = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
    return [self _evaluateScript:script withSourceURL:[NSURL URLWithString:[filePath lastPathComponent]]];
}
// 修改 js 修复文件方法的调用方式
+ (JSValue *)_evaluateScript:(NSString *)script withSourceURL:(NSURL *)resourceURL{
    if (!script || ![JSContext class]) {
        _exceptionBlock(@"script is nil");
        return nil;
    }
    [self startEngine];
    if (!_regex) {
        // 使用正则表达式替换方法调用方式，将 alloc() 这样的函数调用，替换为 __c("alloc")() 形式
        _regex = [NSRegularExpression regularExpressionWithPattern:_regexStr options:0 error:nil];
        // 执行处理后的修复方法
    }
    NSString *formatedScript = [NSString stringWithFormat:@";(function(){try{\n%@\n}catch(e){_OC_catch(e.message, e.stack)}})();", [_regex stringByReplacingMatchesInString:script options:0 range:NSMakeRange(0, script.length) withTemplate:_replaceStr]];
    @try {
        if ([_context respondsToSelector:@selector(evaluateScript:withSourceURL:)]) {
            return [_context evaluateScript:formatedScript withSourceURL:resourceURL];
        } else {
            return [_context evaluateScript:formatedScript];
        }
    }
    @catch (NSException *exception) {
        _exceptionBlock([NSString stringWithFormat:@"%@", exception]);
    }
    return nil;
}
+ (JSValue *)evaluateScriptWithPath:(NSString *)filePath{
    _scriptRootDir = [filePath stringByDeletingLastPathComponent];
    return [self _evaluateScriptWithPath:filePath];
}
#pragma mark - 对象格式化处理


static id genCallbackBlock(JSValue *jsVal) {
    #define BLK_TRAITS_ARG(_idx, _paramName) \
    if (_idx < argTypes.count) { \
        NSString *argType = trim(argTypes[_idx]); \
        if (blockTypeIsScalarPointer(argType)) { \
            [list addObject:formatOCToJS([JPBoxing boxPointer:_paramName])]; \
        } else if (blockTypeIsObject(trim(argTypes[_idx]))) {  \
            [list addObject:formatOCToJS((__bridge id)_paramName)]; \
        } else {  \
            [list addObject:formatOCToJS([NSNumber numberWithLongLong:(long long)_paramName])]; \
        }   \
    }

    NSArray *argTypes = [[jsVal[@"args"] toString] componentsSeparatedByString:@","];
    if (argTypes.count > [jsVal[@"argCount"] toInt32]) {
        argTypes = [argTypes subarrayWithRange:NSMakeRange(1, argTypes.count - 1)];
    }
    id cb = ^id(void *p0, void *p1, void *p2, void *p3, void *p4, void *p5) {
        NSMutableArray *list = [[NSMutableArray alloc] init];
        BLK_TRAITS_ARG(0, p0)
        BLK_TRAITS_ARG(1, p1)
        BLK_TRAITS_ARG(2, p2)
        BLK_TRAITS_ARG(3, p3)
        BLK_TRAITS_ARG(4, p4)
        BLK_TRAITS_ARG(5, p5)
        JSValue *ret = [jsVal[@"cb"] callWithArguments:list];
        return formatJSToOC(ret);
    };
    
    return cb;
}



// 将 js 对象转为 OC 对象 formatJSToOC
static id formatJSToOC(JSValue *jsval) {
    id obj = [jsval toObject];
    if (!obj || [obj isKindOfClass:[NSNull class]]) return _nilObj;
    // 如果是 JPBoxing 类型的，那么解包
    if ([obj isKindOfClass:[JPBoxing class]]) return [obj unbox];
    // 如果是数组类型的，那么把数组里的所有都 format 一遍
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *newArr = [[NSMutableArray alloc] init];
        for (int i = 0; i < [(NSArray*)obj count]; i ++) {
            [newArr addObject:formatJSToOC(jsval[i])];
        }
        return newArr;
    }
    // 如果是字典类型的
    if ([obj isKindOfClass:[NSDictionary class]]) {
        // 如果内部有 __obj 字段
        if (obj[@"__obj"]) {
            // 拿到 __obj 对应的对象
            id ocObj = [obj objectForKey:@"__obj"];
            if ([ocObj isKindOfClass:[JPBoxing class]]) return [ocObj unbox];
            return ocObj;
        } else if (obj[@"__clsName"]) {
            // 如果存在 __clsName 对象，那么把 clsName 对应的 Class 拿出
            return NSClassFromString(obj[@"__clsName"]);
        }
        // 如果是 block
        if (obj[@"__isBlock"]) {
            Class JPBlockClass = NSClassFromString(@"JPBlock");
            if (JPBlockClass && ![jsval[@"blockObj"] isUndefined]) {
                return [JPBlockClass performSelector:@selector(blockWithBlockObj:) withObject:[jsval[@"blockObj"] toObject]];
            } else {
                return genCallbackBlock(jsval);
            }
        }
        NSMutableDictionary *newDict = [[NSMutableDictionary alloc] init];
        for (NSString *key in [obj allKeys]) {
            [newDict setObject:formatJSToOC(jsval[key]) forKey:key];
        }
        return newDict;
    }
    return obj;
}

static id _formatOCToJSList(NSArray *list)
{
    NSMutableArray *arr = [NSMutableArray new];
    for (id obj in list) {
        [arr addObject:formatOCToJS(obj)];
    }
    return arr;
}

// 如果是 NSString，NSNumber，NSDate，NSBlock 直接返回，
// 如果是 NSArray 或者 NSDictionary 把内部解包
// 否则以 {__obj: xxx, __clsName: xxx} 的形式包裹对象
static id _unboxOCObjectToJS(id obj) {
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *newArr = [[NSMutableArray alloc] init];
        for (int i = 0; i < [(NSArray*)obj count]; i ++) {
            [newArr addObject:_unboxOCObjectToJS(obj[i])];
        }
        return newArr;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *newDict = [[NSMutableDictionary alloc] init];
        for (NSString *key in [obj allKeys]) {
            [newDict setObject:_unboxOCObjectToJS(obj[key]) forKey:key];
        }
        return newDict;
    }
    if ([obj isKindOfClass:[NSString class]] ||[obj isKindOfClass:[NSNumber class]] || [obj isKindOfClass:NSClassFromString(@"NSBlock")] || [obj isKindOfClass:[NSDate class]]) {
        return obj;
    }
    return _wrapObj(obj);
}

# pragma mark --js调用OC


static id callSelector(NSString *className, NSString *selectorName, JSValue *arguments, JSValue *instance, BOOL isSuper) {
    // realClsName 是真正要调用的类，和 clsName 的区别在于如果要调用的方法是父类方法，那么 clsName 会变为父类名，而 realClsName 仍然是子类名

    NSString *realClsName = [[instance valueForProperty:@"__realClsName"] toString];
    // 校验调用对象是否是类名，是否是空对象
    if (instance) {
        instance = formatJSToOC(instance);
        if (class_isMetaClass(object_getClass(instance))) {
            className = NSStringFromClass((Class)instance);
            instance = nil;
        } else if (!instance || instance == _nilObj || [instance isKindOfClass:[JPBoxing class]]) {
            return @{@"__isNil": @(YES)};
        }
    }
    // 把参数列表从 JS 转到 OC
    id argumentsObj = formatJSToOC(arguments);
    /**
     如果要执行的方法是"toJS"，即转化为js类型
     对于NSString/NSNumber/NSData 等可以直接转为 js 对象的直接转为 js 默认对象
     对于普通 oc 对象，转为 {__obj: xxx, __clsName: xxx} 的包裹形式
    **/
    if (instance && [selectorName isEqualToString:@"toJS"]) {
        if ([instance isKindOfClass:[NSString class]] || [instance isKindOfClass:[NSDictionary class]] || [instance isKindOfClass:[NSArray class]] || [instance isKindOfClass:[NSDate class]]) {
            return _unboxOCObjectToJS(instance);
        }
    }

    Class cls = instance ? [instance class] : NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    
    NSString *superClassName = nil;
    if (isSuper) {
        // 创建一个 SUPER_${selectorName} 的 SEL
        NSString *superSelectorName = [NSString stringWithFormat:@"SUPER_%@", selectorName];
        SEL superSelector = NSSelectorFromString(superSelectorName);
        // 通过 js 传来的 realClsName 拿到 superCls

        Class superCls;
        if (realClsName.length) {
            Class defineClass = NSClassFromString(realClsName);
            // 如果 realClsName 的父类能找到就用 realClsName 的父类，否则就直接用传过来的 className 转的 cls
            superCls = defineClass ? [defineClass superclass] : [cls superclass];
        } else {
            superCls = [cls superclass];
        }
        // 获取 superCls 对应的原始方法的函数指针

        Method superMethod = class_getInstanceMethod(superCls, selector);
        IMP superIMP = method_getImplementation(superMethod);
        // 给当前的 class 添加一个 superSelector, 形式为 SUPER_XXX 的形式，这个方法的指针指向父类方法
        // 之所以给子类添加一个指向父类实现的方法是因为 OC 中调用父类方法调用者也是子类，是通过转发调用到父类实现的。
        // 这里就是模拟了这个过程，直接给子类添加父类实现的方法
        class_addMethod(cls, superSelector, superIMP, method_getTypeEncoding(superMethod));
        // 因为是给子类动态添加的 ${SUPER_XXX} 的方法，它的实现是指向父类相应的原始方法。如果父类的方法被 JS 重写了，那么 ${SUPER_XXX} 也应该被 JS 重写。所以这里要对 ${SUPER_XXX} 的方法进行 JS 的替换

        NSString *JPSelectorName = [NSString stringWithFormat:@"_JP%@", selectorName];
        JSValue *overideFunction = _JSOverideMethods[superCls][JPSelectorName];
        if (overideFunction) {
            overrideMethod(cls, superSelectorName, overideFunction, NO, NULL);
        }
        
        selector = superSelector;
        superClassName = NSStringFromClass(superCls);
    }
    
    
    NSMutableArray *_markArray;
    // 创建 NSInvocation 并且获取方法签名。其中将缓存存放在 _JSMethodSignatureCache 字典中的操作我认为意义不大。
    // NSInvocation 用于调用方法
    NSInvocation *invocation;
    NSMethodSignature *methodSignature;
    // 缓存实例的方法签名,虽然我觉得用处不大
    if (!_JSMethodSignatureCache) {
        _JSMethodSignatureCache = [[NSMutableDictionary alloc]init];
    }
    if (instance) {
        [_JSMethodSignatureLock lock];
        if (!_JSMethodSignatureCache[cls]) {
            _JSMethodSignatureCache[(id<NSCopying>)cls] = [[NSMutableDictionary alloc]init];
        }
        methodSignature = _JSMethodSignatureCache[cls][selectorName];
        if (!methodSignature) {
            methodSignature = [cls instanceMethodSignatureForSelector:selector];
            methodSignature = fixSignature(methodSignature);
            _JSMethodSignatureCache[cls][selectorName] = methodSignature;
        }
        [_JSMethodSignatureLock unlock];
        if (!methodSignature) {
            _exceptionBlock([NSString stringWithFormat:@"unrecognized selector %@ for instance %@", selectorName, instance]);
            return nil;
        }
        // 创建 NSInvocation
        invocation = [NSInvocation invocationWithMethodSignature:methodSignature];
        [invocation setTarget:instance];
    } else {
        // 如果是类方法，直接获取函数签名
        methodSignature = [cls methodSignatureForSelector:selector];
        methodSignature = fixSignature(methodSignature);
        if (!methodSignature) {
            _exceptionBlock([NSString stringWithFormat:@"unrecognized selector %@ for class %@", selectorName, className]);
            return nil;
        }
        invocation= [NSInvocation invocationWithMethodSignature:methodSignature];
        [invocation setTarget:cls];
    }
    // 设置 NSInvocation 的 SEL
    [invocation setSelector:selector];
    
    NSUInteger numberOfArguments = methodSignature.numberOfArguments;
    NSInteger inputArguments = [(NSArray *)argumentsObj count];
    // 针对可变参数个数的方法。参数个数会大于方法签名的参数的个数就是可变参数方法
    if (inputArguments > numberOfArguments - 2) {
        // calling variable argument method, only support parameter type `id` and return type `id`
        // 只支持参数o都是 id 类型，并且返回类型也是 id 类型。
        id sender = instance != nil ? instance : cls;
        id result = invokeVariableParameterMethod(argumentsObj, methodSignature, sender, selector);
        return formatOCToJS(result);
    }
    
    for (NSUInteger i = 2; i < numberOfArguments; i++) {
        const char *argumentType = [methodSignature getArgumentTypeAtIndex:i];
        id valObj = argumentsObj[i-2];
        // 根据 argumentType 表示的类型，设置 NSInvocation 的参数类型
        switch (argumentType[0] == 'r' ? argumentType[1] : argumentType[0]) {
                // 判断是否是当前的 type，如果是，就设置 invocation 的第 i 个元素设置为该类型，值为 valObj

                #define JP_CALL_ARG_CASE(_typeString, _type, _selector) \
                case _typeString: {                              \
                    _type value = [valObj _selector];                     \
                    [invocation setArgument:&value atIndex:i];\
                    break; \
                }
                
                JP_CALL_ARG_CASE('c', char, charValue)
                JP_CALL_ARG_CASE('C', unsigned char, unsignedCharValue)
                JP_CALL_ARG_CASE('s', short, shortValue)
                JP_CALL_ARG_CASE('S', unsigned short, unsignedShortValue)
                JP_CALL_ARG_CASE('i', int, intValue)
                JP_CALL_ARG_CASE('I', unsigned int, unsignedIntValue)
                JP_CALL_ARG_CASE('l', long, longValue)
                JP_CALL_ARG_CASE('L', unsigned long, unsignedLongValue)
                JP_CALL_ARG_CASE('q', long long, longLongValue)
                JP_CALL_ARG_CASE('Q', unsigned long long, unsignedLongLongValue)
                JP_CALL_ARG_CASE('f', float, floatValue)
                JP_CALL_ARG_CASE('d', double, doubleValue)
                JP_CALL_ARG_CASE('B', BOOL, boolValue)
            // selector类型
            case ':': {
                SEL value = nil;
                if (valObj != _nilObj) {
                    value = NSSelectorFromString(valObj);
                }
                [invocation setArgument:&value atIndex:i];
                break;
            }
            // 结构体类型
            case '{': {
                NSString *typeString = extractStructName([NSString stringWithUTF8String:argumentType]);
                JSValue *val = arguments[i-2];
                // 如果结构体是给定的类型，那么就把 js 的参数转化为该类型的结构体设置到 invocation 中去
                #define JP_CALL_ARG_STRUCT(_type, _methodName) \
                if ([typeString rangeOfString:@#_type].location != NSNotFound) {    \
                    _type value = [val _methodName];  \
                    [invocation setArgument:&value atIndex:i];  \
                    break; \
                }
                // 校验是否是 Rect，Point，Size，Range 四种结构体
                JP_CALL_ARG_STRUCT(CGRect, toRect)
                JP_CALL_ARG_STRUCT(CGPoint, toPoint)
                JP_CALL_ARG_STRUCT(CGSize, toSize)
                JP_CALL_ARG_STRUCT(NSRange, toRange)
                @synchronized (_context) {
                    // 检查是否是通过 defineStruct 定义的结构体
                    // 结构体包含的键为 types 结构体的类型，keys 结构体的u键
                    NSDictionary *structDefine = _registeredStruct[typeString];
                    if (structDefine) {
                        // 拿到结构体的大小
                        size_t size = sizeOfStructTypes(structDefine[@"types"]);
                        // 创建相应大小的内存地址
                        void *ret = malloc(size);
                        // 把 valObj 里的数据复制到 ret 上
                        getStructDataWithDict(ret, valObj, structDefine);
                        // 设置 ret 为 invocation 的参数
                        [invocation setArgument:ret atIndex:i];
                        free(ret);
                        break;
                    }
                }
                
                break;
            }
            case '*':
            case '^': {
                // 如果是 JPBoxing 类型，那么解包,如果不是 JPBoxing 类型，那么继续往下走
                if ([valObj isKindOfClass:[JPBoxing class]]) {
                    void *value = [((JPBoxing *)valObj) unboxPointer];
                    // ^@ 表示一个指向id类型的指针

                    if (argumentType[1] == '@') {
                        if (!_TMPMemoryPool) {
                            _TMPMemoryPool = [[NSMutableDictionary alloc] init];
                        }
                        // 把 JPBoxing 放到 markArray 数组中
                        if (!_markArray) {
                            _markArray = [[NSMutableArray alloc] init];
                        }
                        memset(value, 0, sizeof(id));
                        [_markArray addObject:valObj];
                    }
                    
                    [invocation setArgument:&value atIndex:i];
                    break;
                }
            }
            // class 类型
            case '#': {
                // 如果是 JPBoxing 类型那么解包，如果不是那么继续往下走
                if ([valObj isKindOfClass:[JPBoxing class]]) {
                    Class value = [((JPBoxing *)valObj) unboxClass];
                    [invocation setArgument:&value atIndex:i];
                    break;
                }
            }
            default: {
                // null 类型
                if (valObj == _nullObj) {
                    valObj = [NSNull null];
                    [invocation setArgument:&valObj atIndex:i];
                    break;
                }
                if (valObj == _nilObj ||
                    ([valObj isKindOfClass:[NSNumber class]] && strcmp([valObj objCType], "c") == 0 && ![valObj boolValue])) {
                    valObj = nil;
                    [invocation setArgument:&valObj atIndex:i];
                    break;
                }
                // block 类型
                if ([(JSValue *)arguments[i-2] hasProperty:@"__isBlock"]) {
                    JSValue *blkJSVal = arguments[i-2];
                    Class JPBlockClass = NSClassFromString(@"JPBlock");
                    if (JPBlockClass && ![blkJSVal[@"blockObj"] isUndefined]) {
                        __autoreleasing id cb = [JPBlockClass performSelector:@selector(blockWithBlockObj:) withObject:[blkJSVal[@"blockObj"] toObject]];
                        [invocation setArgument:&cb atIndex:i];
                    } else {
                        __autoreleasing id cb = genCallbackBlock(arguments[i-2]);
                        [invocation setArgument:&cb atIndex:i];
                    }
                } else {
                    [invocation setArgument:&valObj atIndex:i];
                }
            }
        }
    }
    // 执行并返回结果给 js
    // 如果执行的是子类，那么在 _currInvokeSuperClsName 中保存
    if (superClassName) _currInvokeSuperClsName[selectorName] = superClassName;
    // 执行方法
    [invocation invoke];
    // 执行完方法后从 _currInvokeSuperClsName 移除
    if (superClassName) [_currInvokeSuperClsName removeObjectForKey:selectorName];
    if ([_markArray count] > 0) {
        for (JPBoxing *box in _markArray) {
            // pointer 是一个二级指针
            // 执行完方法后，二级指针会被指向一个指针
            void *pointer = [box unboxPointer];
            id obj = *((__unsafe_unretained id *)pointer);
            if (obj) {
                @synchronized(_TMPMemoryPool) {
                    // 如果二级指针指向的地址确实存在，那么就把 obj 暂时保存起来，防止被回收了。
                    // 因为上面的 obj 是 unsafe_unretained 的
                    [_TMPMemoryPool setObject:obj forKey:[NSNumber numberWithInteger:[(NSObject*)obj hash]]];
                }
            }
        }
    }
    
    /*
     最后对 OC 执行返回的结果 JS 化。这里存在一个内存泄漏的问题。即当动态调用的方法是 alloc，new，copy，mutableCopy 时，ARC 不会在尾部插入 release 语句，即多了一次引用计数，需要通过 (__bridge_transfer id) 将 c 对象转为 OC 对象，并自动释放一次引用计数，以此来达到引用计数的平衡：
     */
    char returnType[255];
    strcpy(returnType, [methodSignature methodReturnType]);
    // 不是 void 类型
    // 是 id 类型需要判断是不是创建新对象
    if (strcmp(returnType, @encode(JPDouble)) == 0) {
        // 拿到返回值
        strcpy(returnType, @encode(double));
    }
    if (strcmp(returnType, @encode(JPFloat)) == 0) {
        strcpy(returnType, @encode(float));
    }

    id returnValue;
    if (strncmp(returnType, "v", 1) != 0) {
        if (strncmp(returnType, "@", 1) == 0) {
            void *result;
            [invocation getReturnValue:&result];
            
            //For performance, ignore the other methods prefix with alloc/new/copy/mutableCopy
            if ([selectorName isEqualToString:@"alloc"] || [selectorName isEqualToString:@"new"] ||
                [selectorName isEqualToString:@"copy"] || [selectorName isEqualToString:@"mutableCopy"]) {
                // 针对 alloc 等方法，需要通过 __bridge_transfer 减去引用计数
                returnValue = (__bridge_transfer id)result;
            } else {
                returnValue = (__bridge id)result;
            }
            // // 将 OC 转为 JS 返回
            return formatOCToJS(returnValue);
            
        } else {
            // 其他的各种类型 返回 JSValue
            switch (returnType[0] == 'r' ? returnType[1] : returnType[0]) {
                    
                #define JP_CALL_RET_CASE(_typeString, _type) \
                case _typeString: {                              \
                    _type tempResultSet; \
                    [invocation getReturnValue:&tempResultSet];\
                    returnValue = @(tempResultSet); \
                    break; \
                }
                    
                JP_CALL_RET_CASE('c', char)
                JP_CALL_RET_CASE('C', unsigned char)
                JP_CALL_RET_CASE('s', short)
                JP_CALL_RET_CASE('S', unsigned short)
                JP_CALL_RET_CASE('i', int)
                JP_CALL_RET_CASE('I', unsigned int)
                JP_CALL_RET_CASE('l', long)
                JP_CALL_RET_CASE('L', unsigned long)
                JP_CALL_RET_CASE('q', long long)
                JP_CALL_RET_CASE('Q', unsigned long long)
                JP_CALL_RET_CASE('f', float)
                JP_CALL_RET_CASE('d', double)
                JP_CALL_RET_CASE('B', BOOL)

                case '{': {
                    NSString *typeString = extractStructName([NSString stringWithUTF8String:returnType]);
                    #define JP_CALL_RET_STRUCT(_type, _methodName) \
                    if ([typeString rangeOfString:@#_type].location != NSNotFound) {    \
                        _type result;   \
                        [invocation getReturnValue:&result];    \
                        return [JSValue _methodName:result inContext:_context];    \
                    }
                    JP_CALL_RET_STRUCT(CGRect, valueWithRect)
                    JP_CALL_RET_STRUCT(CGPoint, valueWithPoint)
                    JP_CALL_RET_STRUCT(CGSize, valueWithSize)
                    JP_CALL_RET_STRUCT(NSRange, valueWithRange)
                    @synchronized (_context) {
                        NSDictionary *structDefine = _registeredStruct[typeString];
                        if (structDefine) {
                            size_t size = sizeOfStructTypes(structDefine[@"types"]);
                            void *ret = malloc(size);
                            [invocation getReturnValue:ret];
                            NSDictionary *dict = getDictOfStruct(ret, structDefine);
                            free(ret);
                            return dict;
                        }
                    }
                    break;
                }
                case '*':
                case '^': {
                    void *result;
                    [invocation getReturnValue:&result];
                    returnValue = formatOCToJS([JPBoxing boxPointer:result]);
                    if (strncmp(returnType, "^{CG", 4) == 0) {
                        if (!_pointersToRelease) {
                            _pointersToRelease = [[NSMutableArray alloc] init];
                        }
                        [_pointersToRelease addObject:[NSValue valueWithPointer:result]];
                        CFRetain(result);
                    }
                    break;
                }
                case '#': {
                    Class result;
                    [invocation getReturnValue:&result];
                    returnValue = formatOCToJS([JPBoxing boxClass:result]);
                    break;
                }
            }
            return returnValue;
        }
    }
    return nil;
}

static id (*new_msgSend1)(id, SEL, id,...) = (id (*)(id, SEL, id,...)) objc_msgSend;
static id (*new_msgSend2)(id, SEL, id, id,...) = (id (*)(id, SEL, id, id,...)) objc_msgSend;
static id (*new_msgSend3)(id, SEL, id, id, id,...) = (id (*)(id, SEL, id, id, id,...)) objc_msgSend;
static id (*new_msgSend4)(id, SEL, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id,...)) objc_msgSend;
static id (*new_msgSend5)(id, SEL, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id,...)) objc_msgSend;
static id (*new_msgSend6)(id, SEL, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id,...)) objc_msgSend;
static id (*new_msgSend7)(id, SEL, id, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id,id,...)) objc_msgSend;
static id (*new_msgSend8)(id, SEL, id, id, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id, id, id,...)) objc_msgSend;
static id (*new_msgSend9)(id, SEL, id, id, id, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id, id, id, id, ...)) objc_msgSend;
static id (*new_msgSend10)(id, SEL, id, id, id, id, id, id, id, id, id, id,...) = (id (*)(id, SEL, id, id, id, id, id, id, id, id, id, id,...)) objc_msgSend;
// 转换参数
static id getArgument(id valObj){
    if (valObj == _nilObj ||
        ([valObj isKindOfClass:[NSNumber class]] && strcmp([valObj objCType], "c") == 0 && ![valObj boolValue])) {
        return nil;
    }
    return valObj;
}
static id invokeVariableParameterMethod(NSMutableArray *origArgumentsList, NSMethodSignature *methodSignature, id sender, SEL selector) {
    NSInteger inputArguments = [(NSArray *)origArgumentsList count];
    NSUInteger numberOfArguments = methodSignature.numberOfArguments;
    NSMutableArray *argumentsList = [[NSMutableArray alloc] init];
    for (NSUInteger j = 0; j < inputArguments; j++) {
        NSInteger index = MIN(j + 2, numberOfArguments - 1);
        const char *argumentType = [methodSignature getArgumentTypeAtIndex:index];
        id valObj = origArgumentsList[j];
        char argumentTypeChar = argumentType[0] == 'r' ? argumentType[1] : argumentType[0];
        if (argumentTypeChar == '@') {
            [argumentsList addObject:valObj];
        } else {
            return nil;
        }
    }
    
    id results = nil;
    numberOfArguments = numberOfArguments - 2;
    
    //If you want to debug the macro code below, replace it to the expanded code:
    //https://gist.github.com/bang590/ca3720ae1da594252a2e
    #define JP_G_ARG(_idx) getArgument(argumentsList[_idx])
    #define JP_CALL_MSGSEND_ARG1(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0));
    #define JP_CALL_MSGSEND_ARG2(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1));
    #define JP_CALL_MSGSEND_ARG3(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2));
    #define JP_CALL_MSGSEND_ARG4(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3));
    #define JP_CALL_MSGSEND_ARG5(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4));
    #define JP_CALL_MSGSEND_ARG6(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5));
    #define JP_CALL_MSGSEND_ARG7(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6));
    #define JP_CALL_MSGSEND_ARG8(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6), JP_G_ARG(7));
    #define JP_CALL_MSGSEND_ARG9(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6), JP_G_ARG(7), JP_G_ARG(8));
    #define JP_CALL_MSGSEND_ARG10(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6), JP_G_ARG(7), JP_G_ARG(8), JP_G_ARG(9));
    #define JP_CALL_MSGSEND_ARG11(_num) results = new_msgSend##_num(sender, selector, JP_G_ARG(0), JP_G_ARG(1), JP_G_ARG(2), JP_G_ARG(3), JP_G_ARG(4), JP_G_ARG(5), JP_G_ARG(6), JP_G_ARG(7), JP_G_ARG(8), JP_G_ARG(9), JP_G_ARG(10));
        
    #define JP_IF_REAL_ARG_COUNT(_num) if([argumentsList count] == _num)

    #define JP_DEAL_MSGSEND(_realArgCount, _defineArgCount) \
        if(numberOfArguments == _defineArgCount) { \
            JP_CALL_MSGSEND_ARG##_realArgCount(_defineArgCount) \
        }
    
    JP_IF_REAL_ARG_COUNT(1) { JP_CALL_MSGSEND_ARG1(1) }
    JP_IF_REAL_ARG_COUNT(2) { JP_DEAL_MSGSEND(2, 1) JP_DEAL_MSGSEND(2, 2) }
    JP_IF_REAL_ARG_COUNT(3) { JP_DEAL_MSGSEND(3, 1) JP_DEAL_MSGSEND(3, 2) JP_DEAL_MSGSEND(3, 3) }
    JP_IF_REAL_ARG_COUNT(4) { JP_DEAL_MSGSEND(4, 1) JP_DEAL_MSGSEND(4, 2) JP_DEAL_MSGSEND(4, 3) JP_DEAL_MSGSEND(4, 4) }
    JP_IF_REAL_ARG_COUNT(5) { JP_DEAL_MSGSEND(5, 1) JP_DEAL_MSGSEND(5, 2) JP_DEAL_MSGSEND(5, 3) JP_DEAL_MSGSEND(5, 4) JP_DEAL_MSGSEND(5, 5) }
    JP_IF_REAL_ARG_COUNT(6) { JP_DEAL_MSGSEND(6, 1) JP_DEAL_MSGSEND(6, 2) JP_DEAL_MSGSEND(6, 3) JP_DEAL_MSGSEND(6, 4) JP_DEAL_MSGSEND(6, 5) JP_DEAL_MSGSEND(6, 6) }
    JP_IF_REAL_ARG_COUNT(7) { JP_DEAL_MSGSEND(7, 1) JP_DEAL_MSGSEND(7, 2) JP_DEAL_MSGSEND(7, 3) JP_DEAL_MSGSEND(7, 4) JP_DEAL_MSGSEND(7, 5) JP_DEAL_MSGSEND(7, 6) JP_DEAL_MSGSEND(7, 7) }
    JP_IF_REAL_ARG_COUNT(8) { JP_DEAL_MSGSEND(8, 1) JP_DEAL_MSGSEND(8, 2) JP_DEAL_MSGSEND(8, 3) JP_DEAL_MSGSEND(8, 4) JP_DEAL_MSGSEND(8, 5) JP_DEAL_MSGSEND(8, 6) JP_DEAL_MSGSEND(8, 7) JP_DEAL_MSGSEND(8, 8) }
    JP_IF_REAL_ARG_COUNT(9) { JP_DEAL_MSGSEND(9, 1) JP_DEAL_MSGSEND(9, 2) JP_DEAL_MSGSEND(9, 3) JP_DEAL_MSGSEND(9, 4) JP_DEAL_MSGSEND(9, 5) JP_DEAL_MSGSEND(9, 6) JP_DEAL_MSGSEND(9, 7) JP_DEAL_MSGSEND(9, 8) JP_DEAL_MSGSEND(9, 9) }
    JP_IF_REAL_ARG_COUNT(10) { JP_DEAL_MSGSEND(10, 1) JP_DEAL_MSGSEND(10, 2) JP_DEAL_MSGSEND(10, 3) JP_DEAL_MSGSEND(10, 4) JP_DEAL_MSGSEND(10, 5) JP_DEAL_MSGSEND(10, 6) JP_DEAL_MSGSEND(10, 7) JP_DEAL_MSGSEND(10, 8) JP_DEAL_MSGSEND(10, 9) JP_DEAL_MSGSEND(10, 10) }
    return results;
}


static NSDictionary *defineClass(NSString *classDeclaration, JSValue *instanceMethods, JSValue *classMethods) {
    NSScanner *scanner = [NSScanner scannerWithString:classDeclaration];
    NSString *className;
    NSString *superClassName;
    NSString *protocolNames;
    [scanner scanUpToString:@":" intoString:&className];
    if (!scanner.isAtEnd) {
        scanner.scanLocation = scanner.scanLocation + 1;
        [scanner scanUpToString:@"<" intoString:&superClassName];
        if (!scanner.isAtEnd) {
            scanner.scanLocation = scanner.scanLocation + 1;
            [scanner scanUpToString:@">" intoString:&protocolNames];
        }
    }
    if (!superClassName) superClassName = @"NSObject";
    className = trim(className);
    superClassName = trim(superClassName);
    NSArray *protocols = [protocolNames length] ? [protocolNames componentsSeparatedByString:@","] : nil;
    
    // 反射为类名
    Class cls = NSClassFromString(className);
    if (!cls) {
        // 如果子类没有实例化成功，那么实例化父类
        Class superCls = NSClassFromString(superClassName);
        // 如果父类也没有实例化成功
        if (!superCls) {
            // 直接报错
            _exceptionBlock([NSString stringWithFormat:@"can't find the super class %@", superClassName]);
            return @{@"cls": className};
        }
        // 存在父类，不存在子类，那么创建一个子类时 添加类
        cls = objc_allocateClassPair(superCls, className.UTF8String, 0);
        // 注册类
        objc_registerClassPair(cls);
    }
    // 如果有协议，那么拿到所有的协议名，给类增加协议
    if (protocols.count > 0) {
        for (NSString* protocolName in protocols) {
            Protocol *protocol = objc_getProtocol([trim(protocolName) cStringUsingEncoding:NSUTF8StringEncoding]);
            class_addProtocol (cls, protocol);
        }
    }
    // 增加方法 为什么循环两次？
    for (int i = 0; i < 2; i ++) {
        BOOL isInstance = i == 0;
        JSValue *jsMethods = isInstance ? instanceMethods: classMethods;
        // 如果是类方法那么要取出 cls 的 metaClass，否则直接拿出 cls
        Class currCls = isInstance ? cls: objc_getMetaClass(className.UTF8String);
        NSDictionary *methodDict = [jsMethods toDictionary];
        for (NSString *jsMethodName in methodDict.allKeys) {
            // 通过 methodName 拿到 method 实例
            // method 实例是一个数组，第一个元素表示 method 有几个入参，第二个c元素表示方法实例
            JSValue *jsMethodArr = [jsMethods valueForProperty:jsMethodName];
            int numberOfArg = [jsMethodArr[0] toInt32];
            // 把方法中的 _ 都转为  :
            NSString *selectorName = convertJPSelectorString(jsMethodName);
            // 如果尾部没有：，那么添加：
            if ([selectorName componentsSeparatedByString:@":"].count - 1 < numberOfArg) {
                selectorName = [selectorName stringByAppendingString:@":"];
            }
            
            JSValue *jsMethod = jsMethodArr[1];
            // 判断某个类是否有
            if (class_respondsToSelector(currCls, NSSelectorFromString(selectorName))) {
                // 如果当前类实现了 selectorName 的方法，那么用现在的方法代替原来的方法
                overrideMethod(currCls, selectorName, jsMethod, !isInstance, NULL);
            } else {
                // 如果当前类没有实现 selectorName 方法，那么添加这个方法
                BOOL overrided = NO;
                for (NSString *protocolName in protocols) {
                    char *types = methodTypesInProtocol(protocolName, selectorName, isInstance, YES);
                    if (!types) types = methodTypesInProtocol(protocolName, selectorName, isInstance, NO);
                    if (types) {
                        // 如果当前类实现了 selectorName 的方法，那么用现在的方法代替原来的方法
                        overrideMethod(currCls, selectorName, jsMethod, !isInstance, types);
                        free(types);
                        overrided = YES;
                        break;
                    }
                }
                if (!overrided) {
                    if (![[jsMethodName substringToIndex:1] isEqualToString:@"_"]) {
                        NSMutableString *typeDescStr = [@"@@:" mutableCopy];
                        for (int i = 0; i < numberOfArg; i ++) {
                            [typeDescStr appendString:@"@"];
                        }
                        overrideMethod(currCls, selectorName, jsMethod, !isInstance, [typeDescStr cStringUsingEncoding:NSUTF8StringEncoding]);
                    }
                }
            }
        }
    }
    class_addMethod(cls, @selector(getProp:), (IMP)getPropIMP, "@@:@");
    class_addMethod(cls, @selector(setProp:forKey:), (IMP)setPropIMP, "v@:@@");
    return @{@"cls": className, @"superCls": superClassName};
}

static void overrideMethod(Class cls, NSString *selectorName, JSValue *function, BOOL isClassMethod, const char *typeDescription) {
    // 通过字符串获取SEL
    SEL selector = NSSelectorFromString(selectorName);
    // 没有类型签名的时候获取原来的方法的类型签名
    if (!typeDescription) {
        Method method = class_getInstanceMethod(cls, selector);// 得到实例方法
        typeDescription = (char *)method_getTypeEncoding(method);//字符串编码
    }
    // 获取原来方法的 IMP class_respondsToSelector 判断某个类是否有实例方法
    IMP originalImp = class_respondsToSelector(cls, selector) ? class_getMethodImplementation(cls, selector) : NULL;
    
    // 获取消息转发处理的系统函数实现 IMP 将消息进行转发？
    // 相比较而言，该框架没有没有直接根据返回值所占字节书来判断，而是使用了debugDescription进行判断是否是特殊的结构体，可谓是相当"鸡贼"了.
    
    IMP msgForwardIMP = _objc_msgForward;
    #if !defined(__arm64__)
        if (typeDescription[0] == '{') {
            //In some cases that returns struct, we should use the '_stret' API:
            //http://sealiesoftware.com/blog/archive/2008/10/30/objc_explain_objc_msgSend_stret.html
            //NSMethodSignature knows the detail but has no API to return, we can only get the info from debugDescription.
            // 这个方法签名有多少个参数，第一第二个参数一个是 返回值，一个是 SEL
            NSMethodSignature *methodSignature = [NSMethodSignature signatureWithObjCTypes:typeDescription];
            if ([methodSignature.debugDescription rangeOfString:@"is special struct return? YES"].location != NSNotFound) {
                msgForwardIMP = (IMP)_objc_msgForward_stret;
            }
        }
    #endif
    // 将cls中原来 forwardInvocaiton: 的实现替换成 JPForwardInvocation:函数实现.
    // 如果不是静态方法的实现。替换他
    if (class_getMethodImplementation(cls, @selector(forwardInvocation:)) != (IMP)JPForwardInvocation) {
        // 这里替换方法 class_replaceMethod 不一定返回非空的方法
        IMP originalForwardImp = class_replaceMethod(cls, @selector(forwardInvocation:), (IMP)JPForwardInvocation, "v@:@");
        // 为cls添加新的SEL(ORIGforwardInvocation:)，指向原始 forwardInvocation: 的实现IMP.
        if (originalForwardImp) {
            class_addMethod(cls, @selector(ORIGforwardInvocation:), originalForwardImp, "v@:@");
        }
    }

    [cls jp_fixMethodSignature];
    if (class_respondsToSelector(cls, selector)) {
        NSString *originalSelectorName = [NSString stringWithFormat:@"ORIG%@", selectorName];
        SEL originalSelector = NSSelectorFromString(originalSelectorName);
        if(!class_respondsToSelector(cls, originalSelector)) {
            class_addMethod(cls, originalSelector, originalImp, typeDescription);
        }
    }
    
    NSString *JPSelectorName = [NSString stringWithFormat:@"_JP%@", selectorName];
    // 初始化 _JSOverideMethods 字典
    _initJPOverideMethods(cls);
    // 记录新SEL对应js传过来的待替换目标方法的实现.
    _JSOverideMethods[cls][JPSelectorName] = function;
    
    // Replace the original selector at last, preventing threading issus when
    // the selector get called during the execution of `overrideMethod`
    // 把原来的方法替换为 msgForward 的实现，实现方法转发
    class_replaceMethod(cls, selector, msgForwardIMP, typeDescription);
}

# pragma mark --结构体
static int sizeOfStructTypes(NSString *structTypes) {
    const char *types = [structTypes cStringUsingEncoding:NSUTF8StringEncoding];
    int index = 0;
    int size = 0;
    while (types[index]) {
        switch (types[index]) {
            #define JP_STRUCT_SIZE_CASE(_typeChar, _type)   \
            case _typeChar: \
                size += sizeof(_type);  \
                break;
                
            JP_STRUCT_SIZE_CASE('c', char)
            JP_STRUCT_SIZE_CASE('C', unsigned char)
            JP_STRUCT_SIZE_CASE('s', short)
            JP_STRUCT_SIZE_CASE('S', unsigned short)
            JP_STRUCT_SIZE_CASE('i', int)
            JP_STRUCT_SIZE_CASE('I', unsigned int)
            JP_STRUCT_SIZE_CASE('l', long)
            JP_STRUCT_SIZE_CASE('L', unsigned long)
            JP_STRUCT_SIZE_CASE('q', long long)
            JP_STRUCT_SIZE_CASE('Q', unsigned long long)
            JP_STRUCT_SIZE_CASE('f', float)
            JP_STRUCT_SIZE_CASE('F', CGFloat)
            JP_STRUCT_SIZE_CASE('N', NSInteger)
            JP_STRUCT_SIZE_CASE('U', NSUInteger)
            JP_STRUCT_SIZE_CASE('d', double)
            JP_STRUCT_SIZE_CASE('B', BOOL)
            JP_STRUCT_SIZE_CASE('*', void *)
            JP_STRUCT_SIZE_CASE('^', void *)
            
            default:
                break;
        }
        index ++;
    }
    return size;
}

static void getStructDataWithDict(void *structData, NSDictionary *dict, NSDictionary *structDefine) {
    NSArray *itemKeys = structDefine[@"keys"];
    const char *structTypes = [structDefine[@"types"] cStringUsingEncoding:NSUTF8StringEncoding];
    int position = 0;
    for (int i = 0; i < itemKeys.count; i ++) {
        switch(structTypes[i]) {
            #define JP_STRUCT_DATA_CASE(_typeStr, _type, _transMethod) \
            case _typeStr: { \
                int size = sizeof(_type);    \
                _type val = [dict[itemKeys[i]] _transMethod];   \
                memcpy(structData + position, &val, size);  \
                position += size;    \
                break;  \
            }
                
            JP_STRUCT_DATA_CASE('c', char, charValue)
            JP_STRUCT_DATA_CASE('C', unsigned char, unsignedCharValue)
            JP_STRUCT_DATA_CASE('s', short, shortValue)
            JP_STRUCT_DATA_CASE('S', unsigned short, unsignedShortValue)
            JP_STRUCT_DATA_CASE('i', int, intValue)
            JP_STRUCT_DATA_CASE('I', unsigned int, unsignedIntValue)
            JP_STRUCT_DATA_CASE('l', long, longValue)
            JP_STRUCT_DATA_CASE('L', unsigned long, unsignedLongValue)
            JP_STRUCT_DATA_CASE('q', long long, longLongValue)
            JP_STRUCT_DATA_CASE('Q', unsigned long long, unsignedLongLongValue)
            JP_STRUCT_DATA_CASE('f', float, floatValue)
            JP_STRUCT_DATA_CASE('d', double, doubleValue)
            JP_STRUCT_DATA_CASE('B', BOOL, boolValue)
            JP_STRUCT_DATA_CASE('N', NSInteger, integerValue)
            JP_STRUCT_DATA_CASE('U', NSUInteger, unsignedIntegerValue)
            
            case 'F': {
                int size = sizeof(CGFloat);
                CGFloat val;
                #if CGFLOAT_IS_DOUBLE
                val = [dict[itemKeys[i]] doubleValue];
                #else
                val = [dict[itemKeys[i]] floatValue];
                #endif
                memcpy(structData + position, &val, size);
                position += size;
                break;
            }
            
            case '*':
            case '^': {
                int size = sizeof(void *);
                void *val = [(JPBoxing *)dict[itemKeys[i]] unboxPointer];
                memcpy(structData + position, &val, size);
                break;
            }
            
        }
    }
}
// 取出类名协议名
static NSDictionary *getDictOfStruct(void *structData, NSDictionary *structDefine) {
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    NSArray *itemKeys = structDefine[@"keys"];
    const char *structTypes = [structDefine[@"types"] cStringUsingEncoding:NSUTF8StringEncoding];
    int position = 0;
    
    for (int i = 0; i < itemKeys.count; i ++) {
        switch(structTypes[i]) {
            #define JP_STRUCT_DICT_CASE(_typeName, _type)   \
            case _typeName: { \
                size_t size = sizeof(_type); \
                _type *val = malloc(size);   \
                memcpy(val, structData + position, size);   \
                [dict setObject:@(*val) forKey:itemKeys[i]];    \
                free(val);  \
                position += size;   \
                break;  \
            }
            JP_STRUCT_DICT_CASE('c', char)
            JP_STRUCT_DICT_CASE('C', unsigned char)
            JP_STRUCT_DICT_CASE('s', short)
            JP_STRUCT_DICT_CASE('S', unsigned short)
            JP_STRUCT_DICT_CASE('i', int)
            JP_STRUCT_DICT_CASE('I', unsigned int)
            JP_STRUCT_DICT_CASE('l', long)
            JP_STRUCT_DICT_CASE('L', unsigned long)
            JP_STRUCT_DICT_CASE('q', long long)
            JP_STRUCT_DICT_CASE('Q', unsigned long long)
            JP_STRUCT_DICT_CASE('f', float)
            JP_STRUCT_DICT_CASE('F', CGFloat)
            JP_STRUCT_DICT_CASE('N', NSInteger)
            JP_STRUCT_DICT_CASE('U', NSUInteger)
            JP_STRUCT_DICT_CASE('d', double)
            JP_STRUCT_DICT_CASE('B', BOOL)
            
            case '*':
            case '^': {
                size_t size = sizeof(void *);
                void *val = malloc(size);
                memcpy(val, structData + position, size);
                [dict setObject:[JPBoxing boxPointer:val] forKey:itemKeys[i]];
                position += size;
                break;
            }
            
        }
    }
    return dict;
}

static NSString *extractStructName(NSString *typeEncodeString) {
    NSArray *array = [typeEncodeString componentsSeparatedByString:@"="];
    NSString *typeString = array[0];
    int firstValidIndex = 0;
    for (int i = 0; i< typeString.length; i++) {
        char c = [typeString characterAtIndex:i];
        if (c == '{' || c=='_') {
            firstValidIndex++;
        }else {
            break;
        }
    }
    return [typeString substringFromIndex:firstValidIndex];
}



# pragma mark --消息转发给js对应的实现
static void _initJPOverideMethods(Class cls) {
    if (!_JSOverideMethods) {
        _JSOverideMethods = [[NSMutableDictionary alloc] init];
    }
    if (!_JSOverideMethods[cls]) {
        _JSOverideMethods[(id<NSCopying>)cls] = [[NSMutableDictionary alloc] init];
    }
}
static void JPExecuteORIGForwardInvocation(id slf, SEL selector, NSInvocation *invocation) {
    // 拿到原始的被替换的 forwardInvocation： ORIDforwardInvocation, 然后调用原始的转发方法
    SEL origForwardSelector = @selector(ORIGforwardInvocation:);
    
    if ([slf respondsToSelector:origForwardSelector]) {
        NSMethodSignature *methodSignature = [slf methodSignatureForSelector:origForwardSelector];
        if (!methodSignature) {
            _exceptionBlock([NSString stringWithFormat:@"unrecognized selector -ORIGforwardInvocation: for instance %@", slf]);
            return;
        }
        // 调用原始的转换方法
        NSInvocation *forwardInv= [NSInvocation invocationWithMethodSignature:methodSignature];
        [forwardInv setTarget:slf];
        [forwardInv setSelector:origForwardSelector];
        [forwardInv setArgument:&invocation atIndex:2];
        [forwardInv invoke];
    } else {
        // 如果不存在原始的转发方法，就调用父类的转发方法
        // 这里应该是保底逻辑，一般来说，不会出现调用没有 forwardInvocation 方法的情况
        Class superCls = [[slf class] superclass];
        Method superForwardMethod = class_getInstanceMethod(superCls, @selector(forwardInvocation:));
        void (*superForwardIMP)(id, SEL, NSInvocation *);
        superForwardIMP = (void (*)(id, SEL, NSInvocation *))method_getImplementation(superForwardMethod);
        superForwardIMP(slf, @selector(forwardInvocation:), invocation);
    }
}

static void JPForwardInvocation(__unsafe_unretained id assignSlf, SEL selector, NSInvocation *invocation) {
#ifdef DEBUG
    _JSLastCallStack = [NSThread callStackSymbols];
#endif
    BOOL deallocFlag = NO;
    id slf = assignSlf;
    NSMethodSignature *methodSignature = [invocation methodSignature];
    NSInteger numberOfArguments = [methodSignature numberOfArguments];
    
    NSString *selectorName = NSStringFromSelector(invocation.selector);
    NSString *JPSelectorName = [NSString stringWithFormat:@"_JP%@", selectorName];
    // 判断 JSPSEL 是否有对应的 js 函数的实现，如果没有就原始方法的消息转发的流程
    // （被 defineClass 过的类会被替换 forwardInvocation 方法。如果有方法没有被实现，且没有被 JS重写。那么就会走原始的 forwardInvocation 要找到的是 ORIGforwardInvocation 方法）
    //  这是一个递归方法
    JSValue *jsFunc = getJSFunctionInObjectHierachy(slf, JPSelectorName);
    if (!jsFunc) {
        JPExecuteORIGForwardInvocation(slf, selector, invocation);
        return;
    }
    //  从NSInvocation中获取调用的参数，把self与相应的参数都转换成js对象并封装到一个集合中
    //  js端重写的函数，传递过来是JSValue类型，用callWithArgument:调用js方法，参数也要是js对象.
    NSMutableArray *argList = [[NSMutableArray alloc] init];
    if ([slf class] == slf) {
        // 如果调用的是类方法，那么给入参列表的第一个参数就是一个包含  __clsName 的 object
        [argList addObject:[JSValue valueWithObject:@{@"__clsName": NSStringFromClass([slf class])} inContext:_context]];
    } else if ([selectorName isEqualToString:@"dealloc"]) {
        // 对于被释放的对象，使用 assign 来保存 self 的指针
        // 因为在 dealloc 的时候，系统不让将 self 赋值给一个 weak 对象。（在 dealloc 的时候应该会有一些操作 weak 字典的步骤，所以不能再这个阶段再操作 weak）
        // assign 和 weak 的区别在于 assign 在指向的对象销毁的时候不会把当前指针置为 nil
        // 所以这里最终要自己确保不会在 dealloc 后调用 slf 的方法
        [argList addObject:[JPBoxing boxAssignObj:slf]];
        deallocFlag = YES;
    } else {
        // 否则用 weak 包裹
        [argList addObject:[JPBoxing boxWeakObj:slf]];
    }
    // 这里涉及到OC的type encoding，可以参考Apple的官方guide
    for (NSUInteger i = 2; i < numberOfArguments; i++) {
        const char *argumentType = [methodSignature getArgumentTypeAtIndex:i];
        switch(argumentType[0] == 'r' ? argumentType[1] : argumentType[0]) {
            // 从invocation中获取参数，并将参数添加到argList数组中
            #define JP_FWD_ARG_CASE(_typeChar, _type) \
            case _typeChar: {   \
                _type arg;  \
                [invocation getArgument:&arg atIndex:i];    \
                [argList addObject:@(arg)]; \
                break;  \
            }
            JP_FWD_ARG_CASE('c', char)
            JP_FWD_ARG_CASE('C', unsigned char)
            JP_FWD_ARG_CASE('s', short)
            JP_FWD_ARG_CASE('S', unsigned short)
            JP_FWD_ARG_CASE('i', int)
            JP_FWD_ARG_CASE('I', unsigned int)
            JP_FWD_ARG_CASE('l', long)
            JP_FWD_ARG_CASE('L', unsigned long)
            JP_FWD_ARG_CASE('q', long long)
            JP_FWD_ARG_CASE('Q', unsigned long long)
            JP_FWD_ARG_CASE('f', float)
            JP_FWD_ARG_CASE('d', double)
            JP_FWD_ARG_CASE('B', BOOL)
            case '@': {
                // 处理id类型的参数，使用__unsafe_unretianed参数，避免内存泄露???
                __unsafe_unretained id arg;
                [invocation getArgument:&arg atIndex:i];
                // 对于block参数做特殊处理，需要进行copy；使用_nilObj表示nil，让参数可以完整传递给JS
                if ([arg isKindOfClass:NSClassFromString(@"NSBlock")]) {
                    [argList addObject:(arg ? [arg copy]: _nilObj)];
                } else {
                    [argList addObject:(arg ? arg: _nilObj)];
                }
                break;
            }
            case '{': {
                // 处理结构体类型参数
                // 获取结构体类型的名称，然后根据这个把参数包装为JSValue类型
                NSString *typeString = extractStructName([NSString stringWithUTF8String:argumentType]);
                #define JP_FWD_ARG_STRUCT(_type, _transFunc) \
                if ([typeString rangeOfString:@#_type].location != NSNotFound) {    \
                    _type arg; \
                    [invocation getArgument:&arg atIndex:i];    \
                    [argList addObject:[JSValue _transFunc:arg inContext:_context]];  \
                    break; \
                }
                JP_FWD_ARG_STRUCT(CGRect, valueWithRect)
                JP_FWD_ARG_STRUCT(CGPoint, valueWithPoint)
                JP_FWD_ARG_STRUCT(CGSize, valueWithSize)
                JP_FWD_ARG_STRUCT(NSRange, valueWithRange)
                // 处理自定义类型的结构体
                @synchronized (_context) {
                    NSDictionary *structDefine = _registeredStruct[typeString];
                    if (structDefine) {
                        size_t size = sizeOfStructTypes(structDefine[@"types"]);
                        if (size) {
                            void *ret = malloc(size);
                            [invocation getArgument:ret atIndex:i];
                            NSDictionary *dict = getDictOfStruct(ret, structDefine);
                            [argList addObject:[JSValue valueWithObject:dict inContext:_context]];
                            free(ret);
                            break;
                        }
                    }
                }
                
                break;
            }
            case ':': {
                // 处理selector类型参数
                SEL selector;
                [invocation getArgument:&selector atIndex:i];
                NSString *selectorName = NSStringFromSelector(selector);
                [argList addObject:(selectorName ? selectorName: _nilObj)];
                break;
            }
            case '^':
            case '*': {
                void *arg;
                [invocation getArgument:&arg atIndex:i];
                [argList addObject:[JPBoxing boxPointer:arg]];
                break;
            }
            case '#': {
                // Class类类型
                Class arg;
                [invocation getArgument:&arg atIndex:i];
                [argList addObject:[JPBoxing boxClass:arg]];
                break;
            }
            default: {
                NSLog(@"error type %s", argumentType);
                break;
            }
        }
    }
    // 如果当前调用的方法是 js 引起的，并且 js 调用了一个 super 的方法。那么会在 _currInvokeSuperClsName 中保存一个调用的方法名。这个方法名被加上了前缀 SUPER_。 因此真正调用的时候要把这个前缀替换为 _JP。这样才能找到保存在 JSOverrideMethods 字典中的相应方法

    if (_currInvokeSuperClsName[selectorName]) {
        Class cls = NSClassFromString(_currInvokeSuperClsName[selectorName]);
        NSString *tmpSelectorName = [[selectorName stringByReplacingOccurrencesOfString:@"_JPSUPER_" withString:@"_JP"] stringByReplacingOccurrencesOfString:@"SUPER_" withString:@"_JP"];
        // 如果父类没有重写相应的方法
        if (!_JSOverideMethods[cls][tmpSelectorName]) {
            NSString *ORIGSelectorName = [selectorName stringByReplacingOccurrencesOfString:@"SUPER_" withString:@"ORIG"];
            [argList removeObjectAtIndex:0];
            // 如果父类没有重写这个方法那么就是调用 oc 的方法，oc 直接调用父类的相应方法
            id retObj = callSelector(_currInvokeSuperClsName[selectorName], ORIGSelectorName, [JSValue valueWithObject:argList inContext:_context], [JSValue valueWithObject:@{@"__obj": slf, @"__realClsName": @""} inContext:_context], NO);
            id __autoreleasing ret = formatJSToOC([JSValue valueWithObject:retObj inContext:_context]);
            [invocation setReturnValue:&ret];
            return;
        }
    }
    // 转化为 js 的参数形式，将对象包裹为 {__obj: obj, __clsName: xxx} 的形式
    NSArray *params = _formatOCToJSList(argList);
    char returnType[255];
    // 获取方法的返回参数的签名
    strcpy(returnType, [methodSignature methodReturnType]);
    
    // 判断 returnType 的符号签名

    if (strcmp(returnType, @encode(JPDouble)) == 0) {
        strcpy(returnType, @encode(double));
    }
    if (strcmp(returnType, @encode(JPFloat)) == 0) {
        strcpy(returnType, @encode(float));
    }
    // 先调用 js 重写的方法，得到 返回值 jsval

    // 如果 jsval 不是空，并且需要 isPerformInOC，那么获取其 callback 方法，
    // 执行完后拿到数据转为 js 后调用 callback 方法

    // 如果 jsval 没有 isPerformInOC，那么就是执行完 js 方法后直接往下走
    switch (returnType[0] == 'r' ? returnType[1] : returnType[0]) {
        #define JP_FWD_RET_CALL_JS \
            JSValue *jsval; \
            [_JSMethodForwardCallLock lock];   \
            jsval = [jsFunc callWithArguments:params]; \
            [_JSMethodForwardCallLock unlock]; \
            while (![jsval isNull] && ![jsval isUndefined] && [jsval hasProperty:@"__isPerformInOC"]) { \
                NSArray *args = nil;  \
                JSValue *cb = jsval[@"cb"]; \
                if ([jsval hasProperty:@"sel"]) {   \
                    id callRet = callSelector(![jsval[@"clsName"] isUndefined] ? [jsval[@"clsName"] toString] : nil, [jsval[@"sel"] toString], jsval[@"args"], ![jsval[@"obj"] isUndefined] ? jsval[@"obj"] : nil, NO);  \
                    args = @[[_context[@"_formatOCToJS"] callWithArguments:callRet ? @[callRet] : _formatOCToJSList(@[_nilObj])]];  \
                }   \
                [_JSMethodForwardCallLock lock];    \
                jsval = [cb callWithArguments:args];  \
                [_JSMethodForwardCallLock unlock];  \
            }

        #define JP_FWD_RET_CASE_RET(_typeChar, _type, _retCode)   \
            case _typeChar : { \
                JP_FWD_RET_CALL_JS \
                _retCode \
                [invocation setReturnValue:&ret];\
                break;  \
            }

        #define JP_FWD_RET_CASE(_typeChar, _type, _typeSelector)   \
            JP_FWD_RET_CASE_RET(_typeChar, _type, _type ret = [[jsval toObject] _typeSelector];)   \

        #define JP_FWD_RET_CODE_ID \
            id __autoreleasing ret = formatJSToOC(jsval); \
            if (ret == _nilObj ||   \
                ([ret isKindOfClass:[NSNumber class]] && strcmp([ret objCType], "c") == 0 && ![ret boolValue])) ret = nil;  \

        #define JP_FWD_RET_CODE_POINTER    \
            void *ret; \
            id obj = formatJSToOC(jsval); \
            if ([obj isKindOfClass:[JPBoxing class]]) { \
                ret = [((JPBoxing *)obj) unboxPointer]; \
            }

        #define JP_FWD_RET_CODE_CLASS    \
            Class ret;   \
            ret = formatJSToOC(jsval);


        #define JP_FWD_RET_CODE_SEL    \
            SEL ret;   \
            id obj = formatJSToOC(jsval); \
            if ([obj isKindOfClass:[NSString class]]) { \
                ret = NSSelectorFromString(obj); \
            }

        JP_FWD_RET_CASE_RET('@', id, JP_FWD_RET_CODE_ID)
        JP_FWD_RET_CASE_RET('^', void*, JP_FWD_RET_CODE_POINTER)
        JP_FWD_RET_CASE_RET('*', void*, JP_FWD_RET_CODE_POINTER)
        JP_FWD_RET_CASE_RET('#', Class, JP_FWD_RET_CODE_CLASS)
        JP_FWD_RET_CASE_RET(':', SEL, JP_FWD_RET_CODE_SEL)

        JP_FWD_RET_CASE('c', char, charValue)
        JP_FWD_RET_CASE('C', unsigned char, unsignedCharValue)
        JP_FWD_RET_CASE('s', short, shortValue)
        JP_FWD_RET_CASE('S', unsigned short, unsignedShortValue)
        JP_FWD_RET_CASE('i', int, intValue)
        JP_FWD_RET_CASE('I', unsigned int, unsignedIntValue)
        JP_FWD_RET_CASE('l', long, longValue)
        JP_FWD_RET_CASE('L', unsigned long, unsignedLongValue)
        JP_FWD_RET_CASE('q', long long, longLongValue)
        JP_FWD_RET_CASE('Q', unsigned long long, unsignedLongLongValue)
        JP_FWD_RET_CASE('f', float, floatValue)
        JP_FWD_RET_CASE('d', double, doubleValue)
        JP_FWD_RET_CASE('B', BOOL, boolValue)

        case 'v': {
            JP_FWD_RET_CALL_JS
            break;
        }
        
        case '{': {
            NSString *typeString = extractStructName([NSString stringWithUTF8String:returnType]);
            #define JP_FWD_RET_STRUCT(_type, _funcSuffix) \
            if ([typeString rangeOfString:@#_type].location != NSNotFound) {    \
                JP_FWD_RET_CALL_JS \
                _type ret = [jsval _funcSuffix]; \
                [invocation setReturnValue:&ret];\
                break;  \
            }
            JP_FWD_RET_STRUCT(CGRect, toRect)
            JP_FWD_RET_STRUCT(CGPoint, toPoint)
            JP_FWD_RET_STRUCT(CGSize, toSize)
            JP_FWD_RET_STRUCT(NSRange, toRange)
            
            @synchronized (_context) {
                NSDictionary *structDefine = _registeredStruct[typeString];
                if (structDefine) {
                    size_t size = sizeOfStructTypes(structDefine[@"types"]);
                    JP_FWD_RET_CALL_JS
                    void *ret = malloc(size);
                    NSDictionary *dict = formatJSToOC(jsval);
                    getStructDataWithDict(ret, dict, structDefine);
                    [invocation setReturnValue:ret];
                    free(ret);
                }
            }
            break;
        }
        default: {
            break;
        }
    }
    
    if (_pointersToRelease) {
        for (NSValue *val in _pointersToRelease) {
            void *pointer = NULL;
            [val getValue:&pointer];
            CFRelease(pointer);
        }
        _pointersToRelease = nil;
    }
    // 如果这个方法是 dealloc 方法

    if (deallocFlag) {
        slf = nil;
        Class instClass = object_getClass(assignSlf);
        // 拿到 dealloc 方法实现
        Method deallocMethod = class_getInstanceMethod(instClass, NSSelectorFromString(@"ORIGdealloc"));
        // 调用
        void (*originalDealloc)(__unsafe_unretained id, SEL) = (__typeof__(originalDealloc))method_getImplementation(deallocMethod);
        originalDealloc(assignSlf, NSSelectorFromString(@"dealloc"));
    }
}

static JSValue *getJSFunctionInObjectHierachy(id slf, NSString *selectorName) {
    Class cls = object_getClass(slf);
    // 如果是正在在 js 中调用 oc 一个类中的 super 的方法，那么就通过 _currInvokeSuperClsName 记录下来。因为在调用的过程中由于是 super 方法，selector 会有一个 SUPER_ 的前缀。消息转发到这里的时候需要知道当前调用的其实是一个 super 的方法，需要把 SUPER_ 去除。

    if (_currInvokeSuperClsName[selectorName]) {
        cls = NSClassFromString(_currInvokeSuperClsName[selectorName]);
        selectorName = [selectorName stringByReplacingOccurrencesOfString:@"_JPSUPER_" withString:@"_JP"];
    }
    JSValue *func = _JSOverideMethods[cls][selectorName];
    // 遍历父类找这个方法
    while (!func) {
        cls = class_getSuperclass(cls);
        if (!cls) {
            return nil;
        }
        func = _JSOverideMethods[cls][selectorName];
    }
    return func;
}
@end
