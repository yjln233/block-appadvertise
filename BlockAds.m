/**
 * BlockAds - iOS 去广告插件
 * 纯 ObjC Runtime 实现，无越狱依赖
 * 适用于 arm64 / arm64e，轻松签直接注入
 */

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// MARK: - ObjC Runtime Hook 引擎
// ============================================================

static void hookMethod(Class cls, SEL sel, IMP newIMP, IMP *origIMP) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    if (origIMP) *origIMP = method_getImplementation(method);
    method_setImplementation(method, newIMP);
}

static void hookClassMethod(Class cls, SEL sel, IMP newIMP, IMP *origIMP) {
    if (!cls) return;
    hookMethod(object_getClass(cls), sel, newIMP, origIMP);
}

// ============================================================
// MARK: - 广告检测
// ============================================================

static BOOL isAdClassName(NSString *className) {
    if (!className) return NO;
    static NSArray *adKeywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        adKeywords = @[
            // 穿山甲 / CSJ
            @"BUSplash", @"BUNative", @"BUAdSDK", @"CSJSplash", @"CSJAd",
            // 广点通
            @"GDTSplash", @"GDTUnified", @"GDTNative", @"GDTReward",
            // 快手
            @"KSAd", @"KSSplash",
            // 百度
            @"BaiduMobAd", @"BaiduSplash",
            // Sigmob
            @"WindSplash", @"WindInterstitial", @"SigmobSplash", @"SigmobAd",
            // Google AdMob
            @"GADInterstitial", @"GADBanner", @"GADFullScreen", @"GADRewarded",
            // AppLovin
            @"ALInterstitialAd", @"ALAdView",
            // 聚合 SDK
            @"ABUSplash", @"ABUInterstitial",
            @"ATSplash", @"ATInterstitial",
            @"TradPlusSplash",
            // 通用关键词
            @"SplashAd", @"InterstitialAd", @"RewardVideoAd",
        ];
    });
    for (NSString *kw in adKeywords) {
        if ([className containsString:kw]) return YES;
    }
    return NO;
}

static BOOL isAdURL(NSString *url) {
    if (!url) return NO;
    static NSArray *domains = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        domains = @[
            @"googleads", @"doubleclick", @"googlesyndication",
            @"adservice", @"pagead", @"admob",
            @"ads.tiktok", @"ads-api",
            @"e.qq.com", @"gdt.qq.com", @"mi.gdt.qq.com",
            @"cpro.baidu.com", @"pos.baidu.com",
            @"is.snssdk.com", @"ad.oceanengine.com",
        ];
    });
    for (NSString *d in domains) {
        if ([url containsString:d]) return YES;
    }
    return NO;
}

// ============================================================
// MARK: - 原始 IMP 存储
// ============================================================

static IMP orig_window_addSubview = NULL;
static IMP orig_window_insertSubview = NULL;
static IMP orig_vc_present = NULL;
static IMP orig_wk_loadRequest = NULL;

// ============================================================
// MARK: - UIWindow Hooks
// ============================================================

static void hook_window_addSubview(UIWindow *self, SEL _cmd, UIView *view) {
    if (view && isAdClassName(NSStringFromClass([view class]))) {
        NSLog(@"[BlockAds] 拦截广告视图: %@", NSStringFromClass([view class]));
        return;
    }
    ((void(*)(id, SEL, UIView *))orig_window_addSubview)(self, _cmd, view);
}

static void hook_window_insertSubview(UIWindow *self, SEL _cmd, UIView *view, NSInteger idx) {
    if (view && isAdClassName(NSStringFromClass([view class]))) {
        NSLog(@"[BlockAds] 拦截广告视图: %@", NSStringFromClass([view class]));
        return;
    }
    ((void(*)(id, SEL, UIView *, NSInteger))orig_window_insertSubview)(self, _cmd, view, idx);
}

// ============================================================
// MARK: - UIViewController Hook
// ============================================================

static void hook_vc_present(UIViewController *self, SEL _cmd,
                            UIViewController *vc, BOOL animated, id completion) {
    if (vc && isAdClassName(NSStringFromClass([vc class]))) {
        NSLog(@"[BlockAds] 拦截广告VC: %@", NSStringFromClass([vc class]));
        if (completion) ((void(^)(void))completion)();
        return;
    }
    ((void(*)(id, SEL, UIViewController *, BOOL, id))orig_vc_present)(self, _cmd, vc, animated, completion);
}

// ============================================================
// MARK: - WKWebView Hook
// ============================================================

static void hook_wk_loadRequest(WKWebView *self, SEL _cmd, NSURLRequest *req) {
    if (isAdURL(req.URL.absoluteString)) {
        NSLog(@"[BlockAds] 拦截广告网页: %@", req.URL.absoluteString);
        return;
    }
    ((void(*)(id, SEL, NSURLRequest *))orig_wk_loadRequest)(self, _cmd, req);
}

// ============================================================
// MARK: - 广告 SDK 批量 Hook
// ============================================================

static void emptyMethod(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 拦截: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}
static void emptyMethodArg1(id self, SEL _cmd, id a) {
    NSLog(@"[BlockAds] 拦截: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}
static void emptyMethodArg2(id self, SEL _cmd, id a, id b) {
    NSLog(@"[BlockAds] 拦截: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}
static void emptyMethodArg3(id self, SEL _cmd, id a, id b, id c) {
    NSLog(@"[BlockAds] 拦截: +[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

static void hookMethods(const char *clsName, BOOL isClassMethod, SEL *sels, int count) {
    Class cls = objc_getClass(clsName);
    if (!cls) return;
    NSLog(@"[BlockAds] Hook: %s", clsName);
    for (int i = 0; i < count; i++) {
        Method m = isClassMethod ? class_getClassMethod(cls, sels[i])
                                 : class_getInstanceMethod(cls, sels[i]);
        if (!m) continue;
        int argc = method_getNumberOfArguments(m) - 2;
        IMP imp = (argc >= 3) ? (IMP)emptyMethodArg3 :
                  (argc >= 2) ? (IMP)emptyMethodArg2 :
                  (argc >= 1) ? (IMP)emptyMethodArg1 :
                  (IMP)emptyMethod;
        if (isClassMethod) {
            hookClassMethod(cls, sels[i], imp, NULL);
        } else {
            hookMethod(cls, sels[i], imp, NULL);
        }
    }
}

static void hookAdViewRemoval(const char *clsName) {
    Class cls = objc_getClass(clsName);
    if (!cls) return;
    hookMethod(cls, @selector(didMoveToSuperview), (IMP)(void (*)(UIView *, SEL)){
        ^(UIView *self, SEL _cmd) {
            self.hidden = YES;
            self.alpha = 0;
            [self removeFromSuperview];
        }
    }, NULL);
}

// ============================================================
// MARK: - 构造函数
// ============================================================

__attribute__((constructor))
static void BlockAdsInit(void) {
    NSLog(@"[BlockAds] ==============================");
    NSLog(@"[BlockAds] 去广告插件 v1.0.0 已加载");
    NSLog(@"[BlockAds] ==============================");

    // UIWindow
    hookMethod([UIWindow class], @selector(addSubview:),
               (IMP)hook_window_addSubview, &orig_window_addSubview);
    hookMethod([UIWindow class], @selector(insertSubview:atIndex:),
               (IMP)hook_window_insertSubview, &orig_window_insertSubview);

    // UIViewController
    hookMethod([UIViewController class], @selector(presentViewController:animated:completion:),
               (IMP)hook_vc_present, &orig_vc_present);

    // WKWebView
    hookMethod([WKWebView class], @selector(loadRequest:),
               (IMP)hook_wk_loadRequest, &orig_wk_loadRequest);

    // ---- 穿山甲 / CSJ ----
    SEL adLoad[] = { @selector(loadAdData), @selector(showSplashViewInRootViewController:),
                     @selector(showAdFromRootViewController:) };
    const char *buClasses[] = {
        "BUSplashAdView", "BUSplashAd", "CSJSplashAd",
        "BUNativeExpressInterstitialAd", "BUNativeExpressRewardedVideoAd",
    };
    for (int i = 0; i < 5; i++) hookMethods(buClasses[i], NO, adLoad, 3);
    hookAdViewRemoval("BUNativeExpressBannerView");

    // ---- 广点通 ----
    SEL gdtSels[] = { @selector(loadAd), @selector(loadAdAndShow),
                      @selector(presentAdFromRootViewController:), @selector(showAdFromRootViewController:) };
    hookMethods("GDTSplashAd", NO, gdtSels, 4);
    hookMethods("GDTUnifiedInterstitialAd", NO, gdtSels, 4);
    hookMethods("GDTRewardVideoAd", NO, gdtSels, 4);
    hookMethods("GDTUnifiedNativeAd", NO, gdtSels, 1);
    hookAdViewRemoval("GDTUnifiedBannerView");

    // ---- 快手 ----
    SEL ksSels[] = { @selector(loadAdData) };
    hookMethods("KSSplashAdView", NO, ksSels, 1);
    hookAdViewRemoval("KSSplashAdView");

    // ---- 百度 ----
    SEL bdSels[] = { @selector(load), @selector(show), @selector(showFromViewController:) };
    hookMethods("BaiduMobAdSplash", NO, bdSels, 3);
    hookMethods("BaiduMobAdInterstitial", NO, bdSels, 3);

    // ---- Sigmob ----
    SEL windSels[] = { @selector(loadAdData), @selector(showAdFromRootViewController:) };
    hookMethods("WindSplashAdView", NO, windSels, 2);
    hookMethods("WindInterstitialAd", NO, windSels, 2);
    hookAdViewRemoval("WindSplashAdView");

    // ---- Google AdMob ----
    SEL gadCSels[] = { @selector(loadWithAdUnitID:request:completionHandler:) };
    hookMethods("GADInterstitialAd", YES, gadCSels, 1);
    hookMethods("GADRewardedAd", YES, gadCSels, 1);
    SEL gadBSels[] = { @selector(loadRequest:) };
    hookMethods("GADBannerView", NO, gadBSels, 1);
    hookAdViewRemoval("GADBannerView");

    // ---- AppLovin ----
    SEL alSels[] = { @selector(show), @selector(loadNextAd) };
    hookMethods("ALInterstitialAd", NO, alSels, 2);
    hookMethods("ALAdView", NO, alSels, 2);

    // ---- 聚合 SDK ----
    SEL aggSels[] = { @selector(loadAdData), @selector(loadAd),
                      @selector(showSplashViewInRootViewController:), @selector(showAdFromRootViewController:),
                      @selector(showSplashAdInWindow:), @selector(showInRootViewController:) };
    const char *aggClasses[] = {
        "ABUSplashAd", "ABUInterstitialProAd",
        "ATSplashAd", "ATInterstitialAd", "TradPlusSplashAd",
    };
    for (int i = 0; i < 5; i++) hookMethods(aggClasses[i], NO, aggSels, 6);

    // ---- SDK 初始化拦截 ----
    SEL buInit[] = { @selector(setAppID:), @selector(startWithAsyncCompletionHandler:) };
    hookMethods("BUAdSDKManager", YES, buInit, 2);
    SEL csjInit[] = { @selector(startWithConfig:) };
    hookMethods("CSJAdSDKManager", YES, csjInit, 1);
    SEL gdtInit[] = { @selector(registerAppId:) };
    hookMethods("GDTSDKConfig", YES, gdtInit, 1);
    SEL ksInit[] = { @selector(setAppId:) };
    hookMethods("KSAdSDKManager", YES, ksInit, 1);
    SEL gadInit[] = { @selector(startWithCompletionHandler:) };
    hookMethods("GADMobileAds", NO, gadInit, 1);

    NSLog(@"[BlockAds] Hook 安装完成");
}
