/**
 * BlockAds - iOS 去广告插件 v2.0
 * 纯 ObjC Runtime，无越狱依赖，轻松签注入
 *
 * 核心机制:
 * 1. _dyld_register_func_for_add_image 监听动态库加载，SDK 类出现时立即 hook
 * 2. NSURLProtocol 网络层拦截广告请求
 * 3. UIView addSubview: 视图层拦截广告视图
 * 4. UIViewController present 拦截广告页面
 */

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>

#pragma mark - Hook 引擎

static void swizzleMethod(Class cls, SEL sel, IMP newIMP, IMP *origIMP) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP old = method_getImplementation(m);
    if (origIMP) *origIMP = old;
    // 先尝试 add，处理父类方法的情况
    if (class_addMethod(cls, sel, newIMP, method_getTypeEncoding(m))) {
        // 添加成功说明是继承来的方法，原始 IMP 已经拿到了
    } else {
        method_setImplementation(m, newIMP);
    }
}

static void swizzleClassMethod(Class cls, SEL sel, IMP newIMP, IMP *origIMP) {
    if (!cls) return;
    swizzleMethod(object_getClass(cls), sel, newIMP, origIMP);
}

#pragma mark - 广告域名/URL 匹配

static NSArray<NSString *> *adHostKeywords(void) {
    static NSArray *list = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        list = @[
            // 穿山甲 / 巨量引擎
            @"pangolin-sdk-toutiao", @"is.snssdk.com", @"ad.oceanengine.com",
            @"sf3-fe-tos.pglstatp-toutiao.com", @"lf-ad-bamai.pglstatp-toutiao.com",
            @"toblog.ctobsnssdk.com", @"mon.zijieapi.com",
            @"ether-pack.pangolin-sdk-toutiao.com",
            // 广点通
            @"e.qq.com", @"gdt.qq.com", @"mi.gdt.qq.com", @"adsmind.gdtimg.com",
            @"pgdt.ugdtimg.com", @"qzs.gdtimg.com", @"sdk.e.qq.com",
            // 快手
            @"open.e.kuaishou.com", @"gdfp.gifshow.com", @"adtrack.gifshow.com",
            // 百度
            @"cpro.baidu.com", @"pos.baidu.com", @"mobads.baidu.com",
            @"mobads-logs.baidu.com", @"bgg.baidu.com",
            // Sigmob
            @"sigmob.cn", @"mysigmob.com",
            // Google
            @"googleads", @"doubleclick", @"googlesyndication",
            @"adservice.google", @"pagead2.googlesyndication",
            @"admob", @"app-measurement.com",
            // AppLovin
            @"applovin.com", @"applvn.com",
            // Unity Ads
            @"unityads.unity3d.com", @"auction.unityads.unity3d.com",
            // ironSource
            @"outcome-ssp.supersonicads.com", @"is2-ssl.mzstatic.com",
            // 通用
            @"/openapi/splash", @"/api/ad/", @"/adx/", @"/ad_source/",
        ];
    });
    return list;
}

static BOOL isAdURL(NSString *url) {
    if (!url || url.length == 0) return NO;
    NSString *lower = url.lowercaseString;
    for (NSString *kw in adHostKeywords()) {
        if ([lower containsString:kw]) return YES;
    }
    return NO;
}

#pragma mark - NSURLProtocol 网络层拦截

@interface BlockAdsURLProtocol : NSURLProtocol
@end

@implementation BlockAdsURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *url = request.URL.absoluteString;
    if (isAdURL(url)) {
        NSLog(@"[BlockAds] 网络拦截: %@", url);
        return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    // 返回空响应，终止广告请求
    NSURLResponse *resp = [[NSHTTPURLResponse alloc]
        initWithURL:self.request.URL
        statusCode:200
        HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Type": @"text/plain"}];
    [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[NSData data]];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

#pragma mark - WKWebView 广告拦截 (注入 CSS/JS)

static NSString *adBlockScript(void) {
    return @"(function(){"
        "var css='[class*=\"ad-\"],[class*=\"Ad\"][class*=\"banner\"],[class*=\"splash\"],[id*=\"ad-\"],[id*=\"ad_\"],"
        "[class*=\"广告\"],[class*=\"ad_wrapper\"],[class*=\"ad_container\"],[class*=\"adview\"]"
        "{display:none!important;height:0!important;opacity:0!important;pointer-events:none!important;}';"
        "var s=document.createElement('style');s.textContent=css;document.head.appendChild(s);"
        "var obs=new MutationObserver(function(muts){"
        "  muts.forEach(function(m){"
        "    m.addedNodes.forEach(function(n){"
        "      if(n.nodeType===1&&(n.tagName==='IFRAME'||/ad|banner|splash/i.test(n.className+' '+n.id))){"
        "        n.style.display='none';n.remove();"
        "      }"
        "    });"
        "  });"
        "});"
        "obs.observe(document.body||document.documentElement,{childList:true,subtree:true});"
        "})();";
}

#pragma mark - 广告视图类名检测

static NSArray<NSString *> *adClassKeywords(void) {
    static NSArray *list = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        list = @[
            // 穿山甲
            @"BUSplash", @"BUNativeExpress", @"BUFullscreen", @"BUReward",
            @"BUNativeAd", @"BUBanner", @"BUFeedAd",
            @"CSJSplash", @"CSJAd", @"CSJBanner",
            // 广点通
            @"GDTSplash", @"GDTUnified", @"GDTNative", @"GDTReward",
            // 快手
            @"KSAd", @"KSSplash", @"KSFeed", @"KSInterstitial",
            // 百度
            @"BaiduMobAd", @"BaiduSplash",
            // Sigmob
            @"WindSplash", @"WindInterstitial", @"WindReward",
            @"SigmobSplash", @"SigmobAd",
            // AdMob
            @"GADInterstitial", @"GADBanner", @"GADFullScreen",
            @"GADRewarded", @"GADNativeAd",
            // AppLovin
            @"ALInterstitialAd", @"ALAdView", @"MAInterstitialAd",
            // 聚合
            @"ABUSplash", @"ABUInterstitial", @"ABUBanner", @"ABUReward",
            @"ATSplash", @"ATInterstitial", @"ATBanner", @"ATReward",
            @"TradPlusSplash", @"TradPlusInterstitial",
            // 通用
            @"SplashAdView", @"SplashViewController",
            @"AdViewController", @"AdDialogView",
        ];
    });
    return list;
}

static BOOL isAdClass(NSString *name) {
    if (!name) return NO;
    for (NSString *kw in adClassKeywords()) {
        if ([name containsString:kw]) return YES;
    }
    return NO;
}

#pragma mark - UIView addSubview Hook

static IMP orig_addSubview = NULL;

static void hook_addSubview(UIView *self, SEL _cmd, UIView *view) {
    if (view) {
        NSString *cls = NSStringFromClass([view class]);
        if (isAdClass(cls)) {
            NSLog(@"[BlockAds] 视图拦截: %@", cls);
            view.hidden = YES;
            return;
        }
    }
    ((void(*)(id, SEL, UIView *))orig_addSubview)(self, _cmd, view);
}

#pragma mark - UIView insertSubview:atIndex: Hook

static IMP orig_insertSubview = NULL;

static void hook_insertSubview(UIView *self, SEL _cmd, UIView *view, NSInteger idx) {
    if (view) {
        NSString *cls = NSStringFromClass([view class]);
        if (isAdClass(cls)) {
            NSLog(@"[BlockAds] 视图拦截: %@", cls);
            view.hidden = YES;
            return;
        }
    }
    ((void(*)(id, SEL, UIView *, NSInteger))orig_insertSubview)(self, _cmd, view, idx);
}

#pragma mark - UIView insertSubview:aboveSubview: Hook

static IMP orig_insertAbove = NULL;

static void hook_insertAbove(UIView *self, SEL _cmd, UIView *view, UIView *above) {
    if (view) {
        NSString *cls = NSStringFromClass([view class]);
        if (isAdClass(cls)) {
            NSLog(@"[BlockAds] 视图拦截: %@", cls);
            view.hidden = YES;
            return;
        }
    }
    ((void(*)(id, SEL, UIView *, UIView *))orig_insertAbove)(self, _cmd, view, above);
}

#pragma mark - UIViewController present Hook

static IMP orig_present = NULL;

static void hook_present(UIViewController *self, SEL _cmd,
                         UIViewController *vc, BOOL animated, id completion) {
    if (vc) {
        NSString *cls = NSStringFromClass([vc class]);
        if (isAdClass(cls)) {
            NSLog(@"[BlockAds] VC拦截: %@", cls);
            if (completion) ((void(^)(void))completion)();
            return;
        }
    }
    ((void(*)(id, SEL, UIViewController *, BOOL, id))orig_present)(self, _cmd, vc, animated, completion);
}

#pragma mark - WKWebView Hook

static IMP orig_wk_init = NULL;

static WKWebView *hook_wk_initWithFrame(WKWebView *self, SEL _cmd,
                                         CGRect frame, WKWebViewConfiguration *config) {
    // 注入广告屏蔽脚本
    if (config) {
        WKUserScript *script = [[WKUserScript alloc]
            initWithSource:adBlockScript()
            injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
            forMainFrameOnly:NO];
        [config.userContentController addUserScript:script];
    }
    return ((WKWebView *(*)(id, SEL, CGRect, WKWebViewConfiguration *))orig_wk_init)(self, _cmd, frame, config);
}

#pragma mark - 广告 SDK 延迟 Hook (dyld 回调)

// 空实现，用于替换广告 SDK 方法
static void stub_void(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 已屏蔽: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}
static void stub_arg1(id self, SEL _cmd, id a) {
    NSLog(@"[BlockAds] 已屏蔽: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}
static void stub_arg2(id self, SEL _cmd, id a, id b) {
    NSLog(@"[BlockAds] 已屏蔽: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}
static void stub_arg3(id self, SEL _cmd, id a, id b, id c) {
    NSLog(@"[BlockAds] 已屏蔽: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

static IMP stubForArgCount(int argc) {
    if (argc >= 3) return (IMP)stub_arg3;
    if (argc >= 2) return (IMP)stub_arg2;
    if (argc >= 1) return (IMP)stub_arg1;
    return (IMP)stub_void;
}

static void hookAllSelectors(Class cls, BOOL isClassMethod, SEL *sels, int count) {
    if (!cls) return;
    Class target = isClassMethod ? object_getClass(cls) : cls;
    for (int i = 0; i < count; i++) {
        Method m = isClassMethod ? class_getClassMethod(cls, sels[i])
                                 : class_getInstanceMethod(cls, sels[i]);
        if (!m) continue;
        int argc = method_getNumberOfArguments(m) - 2;
        method_setImplementation(m, stubForArgCount(argc));
    }
}

// 记录已 hook 的类，防止重复
static NSMutableSet *hookedClasses = nil;

static void tryHookAdClasses(void) {
    // 广告 SDK 类名 -> 要 hook 的方法
    struct {
        const char *cls;
        BOOL isClass; // 是否 hook 类方法
        SEL sels[8];
        int count;
    } targets[] = {
        // ---- 穿山甲 / CSJ ----
        {"BUSplashAdView",   NO, {@selector(loadAdData), @selector(showSplashViewInRootViewController:), @selector(showInWindow:withBottomView:)}, 3},
        {"BUSplashAd",       NO, {@selector(loadAdData), @selector(showSplashViewInRootViewController:)}, 2},
        {"CSJSplashAd",      NO, {@selector(loadAdData), @selector(showSplashViewInRootViewController:)}, 2},
        {"BUNativeExpressInterstitialAd", NO, {@selector(loadAdData), @selector(showAdFromRootViewController:)}, 2},
        {"BUNativeExpressBannerView",     NO, {@selector(loadAdData)}, 1},
        {"BUNativeExpressRewardedVideoAd",NO, {@selector(loadAdData), @selector(showAdFromRootViewController:)}, 2},
        {"BUNativeExpressFullscreenVideoAd",NO,{@selector(loadAdData), @selector(showAdFromRootViewController:)}, 2},
        {"BUAdSDKManager",   YES, {@selector(setAppID:), @selector(startWithAsyncCompletionHandler:)}, 2},
        {"CSJAdSDKManager",  YES, {@selector(startWithConfig:)}, 1},

        // ---- 广点通 ----
        {"GDTSplashAd",               NO, {@selector(loadAd), @selector(loadAdAndShow), @selector(showAdInWindow:withBottomView:skipView:)}, 3},
        {"GDTUnifiedInterstitialAd",   NO, {@selector(loadAd), @selector(presentAdFromRootViewController:)}, 2},
        {"GDTUnifiedBannerView",       NO, {@selector(loadAdAndShow)}, 1},
        {"GDTUnifiedNativeAd",         NO, {@selector(loadAd), @selector(loadAdWithAdCount:)}, 2},
        {"GDTRewardVideoAd",           NO, {@selector(loadAd), @selector(showAdFromRootViewController:)}, 2},
        {"GDTSDKConfig",     YES, {@selector(registerAppId:)}, 1},

        // ---- 快手 ----
        {"KSSplashAdView",   NO, {@selector(loadAdData)}, 1},
        {"KSAdSplashManager",NO, {@selector(loadSplashAdWithRequest:), @selector(showSplashAdInWindow:)}, 2},
        {"KSAdSDKManager",   YES, {@selector(setAppId:)}, 1},

        // ---- 百度 ----
        {"BaiduMobAdSplash",       NO, {@selector(load), @selector(show)}, 2},
        {"BaiduMobAdInterstitial", NO, {@selector(load), @selector(showFromViewController:)}, 2},
        {"BaiduMobAdNative",       NO, {@selector(requestNativeAds)}, 1},

        // ---- Sigmob ----
        {"WindSplashAdView",   NO, {@selector(loadAdData)}, 1},
        {"WindInterstitialAd", NO, {@selector(loadAdData), @selector(showAdFromRootViewController:)}, 2},
        {"WindRewardVideoAd",  NO, {@selector(loadAdData), @selector(showAdFromRootViewController:)}, 2},

        // ---- AdMob ----
        {"GADInterstitialAd", YES, {@selector(loadWithAdUnitID:request:completionHandler:)}, 1},
        {"GADRewardedAd",     YES, {@selector(loadWithAdUnitID:request:completionHandler:)}, 1},
        {"GADBannerView",     NO, {@selector(loadRequest:)}, 1},
        {"GADMobileAds",      NO, {@selector(startWithCompletionHandler:)}, 1},

        // ---- AppLovin ----
        {"ALInterstitialAd", NO, {@selector(show), @selector(showAd:)}, 2},
        {"ALAdView",         NO, {@selector(loadNextAd), @selector(render:)}, 2},

        // ---- GroMore / TopOn / TradPlus ----
        {"ABUSplashAd",          NO, {@selector(loadAdData), @selector(showSplashViewInRootViewController:)}, 2},
        {"ABUInterstitialProAd", NO, {@selector(loadAdData), @selector(showAdFromRootViewController:)}, 2},
        {"ABURewardedVideoAd",   NO, {@selector(loadAdData), @selector(showAdFromRootViewController:)}, 2},
        {"ATSplashAd",           NO, {@selector(loadAd), @selector(showSplashAdInWindow:)}, 2},
        {"ATInterstitialAd",     NO, {@selector(loadAd), @selector(showInRootViewController:)}, 2},
        {"TradPlusSplashAd",     NO, {@selector(loadAd)}, 1},
    };

    int total = sizeof(targets) / sizeof(targets[0]);
    for (int i = 0; i < total; i++) {
        NSString *name = [NSString stringWithUTF8String:targets[i].cls];
        if ([hookedClasses containsObject:name]) continue;

        Class cls = objc_getClass(targets[i].cls);
        if (!cls) continue;

        NSLog(@"[BlockAds] Hook SDK类: %s", targets[i].cls);
        hookAllSelectors(cls, targets[i].isClass, targets[i].sels, targets[i].count);
        [hookedClasses addObject:name];
    }
}

// dyld 镜像加载回调 - 每当有新的动态库加载时触发
static void onImageAdded(const struct mach_header *mh, intptr_t slide) {
    // 在主线程异步执行，确保类已注册完成
    dispatch_async(dispatch_get_main_queue(), ^{
        tryHookAdClasses();
    });
}

#pragma mark - 定时扫描 & 移除已显示的广告视图

static void scanAndRemoveAdViews(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        for (UIView *sub in window.subviews) {
            if (isAdClass(NSStringFromClass([sub class]))) {
                NSLog(@"[BlockAds] 扫描移除: %@", NSStringFromClass([sub class]));
                sub.hidden = YES;
                sub.alpha = 0;
                [sub removeFromSuperview];
            }
        }
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void BlockAdsInit(void) {
    NSLog(@"[BlockAds] ======================================");
    NSLog(@"[BlockAds] 去广告插件 v2.0 已加载");
    NSLog(@"[BlockAds] ======================================");

    hookedClasses = [NSMutableSet set];

    // 1. 注册 NSURLProtocol 网络拦截
    [NSURLProtocol registerClass:[BlockAdsURLProtocol class]];
    NSLog(@"[BlockAds] NSURLProtocol 网络拦截已启用");

    // 同时 hook WKWebView 的 URLSchemeHandler 和 URLProtocol 注册
    // WKWebView 默认不走 NSURLProtocol，需要通过私有 API 注册
    Class browsingCtx = NSClassFromString(@"WKBrowsingContextController");
    if (browsingCtx) {
        SEL regSel = NSSelectorFromString(@"registerSchemeForCustomProtocol:");
        if ([browsingCtx respondsToSelector:regSel]) {
            ((void(*)(id, SEL, id))objc_msgSend)(browsingCtx, regSel, @"http");
            ((void(*)(id, SEL, id))objc_msgSend)(browsingCtx, regSel, @"https");
            NSLog(@"[BlockAds] WKWebView 网络拦截已启用");
        }
    }

    // 2. Hook UIView 系列方法 (所有视图，不只是 UIWindow)
    swizzleMethod([UIView class], @selector(addSubview:),
                  (IMP)hook_addSubview, &orig_addSubview);
    swizzleMethod([UIView class], @selector(insertSubview:atIndex:),
                  (IMP)hook_insertSubview, &orig_insertSubview);
    swizzleMethod([UIView class], @selector(insertSubview:aboveSubview:),
                  (IMP)hook_insertAbove, &orig_insertAbove);
    NSLog(@"[BlockAds] UIView hook 已启用");

    // 3. Hook UIViewController present
    swizzleMethod([UIViewController class],
                  @selector(presentViewController:animated:completion:),
                  (IMP)hook_present, &orig_present);
    NSLog(@"[BlockAds] UIViewController hook 已启用");

    // 4. Hook WKWebView 注入广告屏蔽脚本
    swizzleMethod([WKWebView class],
                  @selector(initWithFrame:configuration:),
                  (IMP)hook_wk_initWithFrame, &orig_wk_init);
    NSLog(@"[BlockAds] WKWebView script 注入已启用");

    // 5. 尝试 hook 已加载的广告 SDK 类
    tryHookAdClasses();

    // 6. 注册 dyld 回调，监听后续动态库加载
    _dyld_register_func_for_add_image(onImageAdded);
    NSLog(@"[BlockAds] dyld 镜像监听已启用");

    // 7. 启动定时扫描，兜底移除漏网广告视图
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // App 启动 2 秒后开始扫描
        NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            scanAndRemoveAdViews();
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        // 10 秒后停止定时扫描 (开屏广告一般在前几秒)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [timer invalidate];
            NSLog(@"[BlockAds] 定时扫描已停止");
        });
    });

    NSLog(@"[BlockAds] 所有拦截机制已就绪");
}
