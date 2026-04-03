/**
 * BlockAds - iOS 去广告插件 v3.0
 * 纯 ObjC Runtime，无越狱依赖，轻松签注入
 *
 * 核心机制:
 * 1. _dyld_register_func_for_add_image 监听动态库加载，SDK 类出现时立即 hook
 * 2. NSURLProtocol 网络层拦截广告请求
 * 3. UIView addSubview 视图层拦截广告视图
 * 4. UIViewController present 拦截广告页面
 * 5. 主动回调 delegate 通知"广告关闭/失败"，避免 app 黑屏等待
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
    if (class_addMethod(cls, sel, newIMP, method_getTypeEncoding(m))) {
    } else {
        method_setImplementation(m, newIMP);
    }
}

static void swizzleClassMethod(Class cls, SEL sel, IMP newIMP, IMP *origIMP) {
    if (!cls) return;
    swizzleMethod(object_getClass(cls), sel, newIMP, origIMP);
}

#pragma mark - 通用 delegate 回调工具

// 安全地给 delegate 发消息，delegate 可能不响应某些 selector
static void safeCallDelegate(id delegate, SEL sel, id arg) {
    if (!delegate || !sel) return;
    if ([delegate respondsToSelector:sel]) {
        ((void(*)(id, SEL, id))objc_msgSend)(delegate, sel, arg);
    }
}

static void safeCallDelegate2(id delegate, SEL sel, id arg1, id arg2) {
    if (!delegate || !sel) return;
    if ([delegate respondsToSelector:sel]) {
        ((void(*)(id, SEL, id, id))objc_msgSend)(delegate, sel, arg1, arg2);
    }
}

// 获取广告对象的 delegate (各 SDK 都用 delegate 属性)
static id getDelegate(id adObj) {
    if (!adObj) return nil;
    // 尝试常见的 delegate 属性名
    SEL delegateSels[] = {
        @selector(delegate),
        NSSelectorFromString(@"splashDelegate"),
        NSSelectorFromString(@"interstitialDelegate"),
        NSSelectorFromString(@"rewardDelegate"),
    };
    for (int i = 0; i < 4; i++) {
        if ([adObj respondsToSelector:delegateSels[i]]) {
            id d = ((id(*)(id, SEL))objc_msgSend)(adObj, delegateSels[i]);
            if (d) return d;
        }
    }
    return nil;
}

// 构造一个通用 NSError
static NSError *adBlockError(void) {
    return [NSError errorWithDomain:@"BlockAds" code:-1
            userInfo:@{NSLocalizedDescriptionKey: @"Ad blocked"}];
}

#pragma mark - 广告域名/URL 匹配

static NSArray<NSString *> *adHostKeywords(void) {
    static NSArray *list = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        list = @[
            @"pangolin-sdk-toutiao", @"is.snssdk.com", @"ad.oceanengine.com",
            @"sf3-fe-tos.pglstatp-toutiao.com", @"lf-ad-bamai.pglstatp-toutiao.com",
            @"toblog.ctobsnssdk.com", @"mon.zijieapi.com",
            @"ether-pack.pangolin-sdk-toutiao.com",
            @"e.qq.com", @"gdt.qq.com", @"mi.gdt.qq.com", @"adsmind.gdtimg.com",
            @"pgdt.ugdtimg.com", @"qzs.gdtimg.com", @"sdk.e.qq.com",
            @"open.e.kuaishou.com", @"gdfp.gifshow.com", @"adtrack.gifshow.com",
            @"cpro.baidu.com", @"pos.baidu.com", @"mobads.baidu.com",
            @"mobads-logs.baidu.com", @"bgg.baidu.com",
            @"sigmob.cn", @"mysigmob.com",
            @"googleads", @"doubleclick", @"googlesyndication",
            @"adservice.google", @"pagead2.googlesyndication",
            @"admob", @"app-measurement.com",
            @"applovin.com", @"applvn.com",
            @"unityads.unity3d.com", @"auction.unityads.unity3d.com",
            @"outcome-ssp.supersonicads.com",
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
    NSURLResponse *resp = [[NSHTTPURLResponse alloc]
        initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Type": @"text/plain"}];
    [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[NSData data]];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

#pragma mark - WKWebView 广告拦截脚本

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
            @"BUSplash", @"BUNativeExpress", @"BUFullscreen", @"BUReward",
            @"BUNativeAd", @"BUBanner", @"BUFeedAd",
            @"CSJSplash", @"CSJAd", @"CSJBanner",
            @"GDTSplash", @"GDTUnified", @"GDTNative", @"GDTReward",
            @"KSAd", @"KSSplash", @"KSFeed", @"KSInterstitial",
            @"BaiduMobAd", @"BaiduSplash",
            @"WindSplash", @"WindInterstitial", @"WindReward",
            @"SigmobSplash", @"SigmobAd",
            @"GADInterstitial", @"GADBanner", @"GADFullScreen",
            @"GADRewarded", @"GADNativeAd",
            @"ALInterstitialAd", @"ALAdView", @"MAInterstitialAd",
            @"ABUSplash", @"ABUInterstitial", @"ABUBanner", @"ABUReward",
            @"ATSplash", @"ATInterstitial", @"ATBanner", @"ATReward",
            @"TradPlusSplash", @"TradPlusInterstitial",
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

#pragma mark - UIView Hook

static IMP orig_addSubview = NULL;
static IMP orig_insertSubview = NULL;
static IMP orig_insertAbove = NULL;

static void hook_addSubview(UIView *self, SEL _cmd, UIView *view) {
    if (view && isAdClass(NSStringFromClass([view class]))) {
        NSLog(@"[BlockAds] 视图拦截: %@", NSStringFromClass([view class]));
        view.hidden = YES;
        return;
    }
    ((void(*)(id, SEL, UIView *))orig_addSubview)(self, _cmd, view);
}

static void hook_insertSubview(UIView *self, SEL _cmd, UIView *view, NSInteger idx) {
    if (view && isAdClass(NSStringFromClass([view class]))) {
        NSLog(@"[BlockAds] 视图拦截: %@", NSStringFromClass([view class]));
        view.hidden = YES;
        return;
    }
    ((void(*)(id, SEL, UIView *, NSInteger))orig_insertSubview)(self, _cmd, view, idx);
}

static void hook_insertAbove(UIView *self, SEL _cmd, UIView *view, UIView *above) {
    if (view && isAdClass(NSStringFromClass([view class]))) {
        NSLog(@"[BlockAds] 视图拦截: %@", NSStringFromClass([view class]));
        view.hidden = YES;
        return;
    }
    ((void(*)(id, SEL, UIView *, UIView *))orig_insertAbove)(self, _cmd, view, above);
}

#pragma mark - UIViewController present Hook

static IMP orig_present = NULL;

static void hook_present(UIViewController *self, SEL _cmd,
                         UIViewController *vc, BOOL animated, id completion) {
    if (vc && isAdClass(NSStringFromClass([vc class]))) {
        NSLog(@"[BlockAds] VC拦截: %@", NSStringFromClass([vc class]));
        if (completion) ((void(^)(void))completion)();
        return;
    }
    ((void(*)(id, SEL, UIViewController *, BOOL, id))orig_present)(self, _cmd, vc, animated, completion);
}

#pragma mark - WKWebView Hook

static IMP orig_wk_init = NULL;

static WKWebView *hook_wk_initWithFrame(WKWebView *self, SEL _cmd,
                                         CGRect frame, WKWebViewConfiguration *config) {
    if (config) {
        WKUserScript *script = [[WKUserScript alloc]
            initWithSource:adBlockScript()
            injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
            forMainFrameOnly:NO];
        [config.userContentController addUserScript:script];
    }
    return ((WKWebView *(*)(id, SEL, CGRect, WKWebViewConfiguration *))orig_wk_init)(self, _cmd, frame, config);
}

#pragma mark - 穿山甲 / CSJ 带 delegate 回调的 Hook

// 穿山甲开屏: 拦截 loadAdData 后立即回调 delegate
// delegate 方法: splashAdDidClose: / splashAd:didFailWithError:
static void bu_splash_loadAdData(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 穿山甲开屏 loadAdData -> 立即回调关闭");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        // 先尝试 didFailWithError，再 didClose
        safeCallDelegate2(delegate, NSSelectorFromString(@"splashAd:didFailWithError:"), self, adBlockError());
        safeCallDelegate(delegate, NSSelectorFromString(@"splashAdDidClose:"), self);
        safeCallDelegate(delegate, NSSelectorFromString(@"splashAdDidCloseOtherController:"), self);
        // CSJ 新版回调
        safeCallDelegate2(delegate, NSSelectorFromString(@"splashAdLoadFail:error:"), self, adBlockError());
        safeCallDelegate(delegate, NSSelectorFromString(@"splashAdDidClose:closeType:"), self);
    });
}

static void bu_splash_show(id self, SEL _cmd, id vc) {
    NSLog(@"[BlockAds] 穿山甲开屏 show -> 立即回调关闭");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate(delegate, NSSelectorFromString(@"splashAdDidClose:"), self);
        safeCallDelegate(delegate, NSSelectorFromString(@"splashAdDidCloseOtherController:"), self);
    });
}

// 穿山甲插屏
static void bu_interstitial_loadAdData(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 穿山甲插屏 loadAdData -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"nativeExpressInterstitialAd:didFailWithError:"), self, adBlockError());
    });
}

static void bu_interstitial_show(id self, SEL _cmd, id vc) {
    NSLog(@"[BlockAds] 穿山甲插屏 show -> 回调关闭");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate(delegate, NSSelectorFromString(@"nativeExpressInterstitialAdDidClose:"), self);
    });
}

// 穿山甲激励视频
static void bu_reward_loadAdData(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 穿山甲激励视频 loadAdData -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"nativeExpressRewardedVideoAd:didFailWithError:"), self, adBlockError());
    });
}

// 穿山甲 Banner
static void bu_banner_loadAdData(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 穿山甲Banner loadAdData -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"nativeExpressBannerAdView:didLoadFailWithError:"), self, adBlockError());
    });
}

// 穿山甲全屏视频
static void bu_fullscreen_loadAdData(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 穿山甲全屏视频 loadAdData -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"nativeExpressFullscreenVideoAd:didFailWithError:"), self, adBlockError());
    });
}

#pragma mark - 广点通 带 delegate 回调的 Hook

static void gdt_splash_loadAd(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 广点通开屏 loadAd -> 回调关闭");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"splashAdFailToPresent:withError:"), self, adBlockError());
        safeCallDelegate(delegate, NSSelectorFromString(@"splashAdClosed:"), self);
        safeCallDelegate(delegate, NSSelectorFromString(@"splashAdDidClose:"), self);
    });
}

static void gdt_splash_show(id self, SEL _cmd, id a, id b, id c) {
    NSLog(@"[BlockAds] 广点通开屏 show -> 回调关闭");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate(delegate, NSSelectorFromString(@"splashAdClosed:"), self);
        safeCallDelegate(delegate, NSSelectorFromString(@"splashAdDidClose:"), self);
    });
}

static void gdt_interstitial_loadAd(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 广点通插屏 loadAd -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"unifiedInterstitialFailToLoadAd:error:"), self, adBlockError());
    });
}

static void gdt_interstitial_present(id self, SEL _cmd, id vc) {
    NSLog(@"[BlockAds] 广点通插屏 present -> 回调关闭");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate(delegate, NSSelectorFromString(@"unifiedInterstitialAdDidClose:"), self);
    });
}

static void gdt_reward_loadAd(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 广点通激励视频 loadAd -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"gdt_rewardVideoAdDidFailToLoad:error:"), self, adBlockError());
    });
}

static void gdt_native_loadAd(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 广点通原生 loadAd -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"gdt_unifiedNativeAdLoaded:error:"), self, adBlockError());
    });
}

static void gdt_banner_loadAd(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 广点通Banner loadAdAndShow -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"unifiedBannerViewFailedToLoad:error:"), self, adBlockError());
    });
}

#pragma mark - 快手 带 delegate 回调的 Hook

static void ks_splash_loadAdData(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 快手开屏 loadAdData -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"ksad_splashAdDidFailToLoad:withError:"), self, adBlockError());
        safeCallDelegate(delegate, NSSelectorFromString(@"ksad_splashAdDidClose:"), self);
    });
}

#pragma mark - 百度 带 delegate 回调的 Hook

static void bd_splash_load(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 百度开屏 load -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"splashAdLoadFail:"), self, adBlockError());
        safeCallDelegate(delegate, NSSelectorFromString(@"splashAdClose:"), self);
        safeCallDelegate(delegate, NSSelectorFromString(@"splashAdClosed:"), self);
    });
}

static void bd_interstitial_load(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 百度插屏 load -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"interstitialAdLoadFail:"), self, adBlockError());
    });
}

#pragma mark - Sigmob/Wind 带 delegate 回调的 Hook

static void wind_splash_loadAdData(id self, SEL _cmd) {
    NSLog(@"[BlockAds] Sigmob开屏 loadAdData -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"onSplashAdLoadFail:error:"), self, adBlockError());
        safeCallDelegate(delegate, NSSelectorFromString(@"onSplashAdClosed:"), self);
    });
}

static void wind_interstitial_loadAdData(id self, SEL _cmd) {
    NSLog(@"[BlockAds] Sigmob插屏 loadAdData -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"onInterstitialAdLoadFail:error:"), self, adBlockError());
    });
}

#pragma mark - AdMob 带 callback 的 Hook

// GADInterstitialAd +loadWithAdUnitID:request:completionHandler:
static void gad_interstitial_load(id self, SEL _cmd, id unitID, id request, void (^handler)(id, NSError *)) {
    NSLog(@"[BlockAds] AdMob插屏 load -> 回调失败");
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(nil, adBlockError());
        });
    }
}

// GADRewardedAd +loadWithAdUnitID:request:completionHandler:
static void gad_reward_load(id self, SEL _cmd, id unitID, id request, void (^handler)(id, NSError *)) {
    NSLog(@"[BlockAds] AdMob激励 load -> 回调失败");
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(nil, adBlockError());
        });
    }
}

static void gad_banner_load(id self, SEL _cmd, id request) {
    NSLog(@"[BlockAds] AdMob Banner load -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"bannerView:didFailToReceiveAdWithError:"), self, adBlockError());
    });
}

static void gad_mobileads_start(id self, SEL _cmd, void (^handler)(id)) {
    NSLog(@"[BlockAds] AdMob 初始化 -> 立即回调完成");
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(nil);
        });
    }
}

#pragma mark - AppLovin Hook

static void al_interstitial_show(id self, SEL _cmd) {
    NSLog(@"[BlockAds] AppLovin插屏 show -> 回调关闭");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate(delegate, NSSelectorFromString(@"adHidden:"), self);
    });
}

#pragma mark - GroMore/TopOn/TradPlus 聚合 SDK Hook

static void agg_splash_loadAdData(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 聚合开屏 loadAdData -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        // GroMore
        safeCallDelegate2(delegate, NSSelectorFromString(@"splashAd:didFailWithError:"), self, adBlockError());
        safeCallDelegate(delegate, NSSelectorFromString(@"splashAdDidClose:"), self);
        // TopOn
        safeCallDelegate2(delegate, NSSelectorFromString(@"didFailToLoadADWithPlacementID:error:"),
                          ((id(*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"placementID")) ?: @"",
                          adBlockError());
    });
}

static void agg_splash_show(id self, SEL _cmd, id arg) {
    NSLog(@"[BlockAds] 聚合开屏 show -> 回调关闭");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate(delegate, NSSelectorFromString(@"splashAdDidClose:"), self);
        safeCallDelegate2(delegate, NSSelectorFromString(@"splashAdDidClose:remainAds:"), self, @(0));
    });
}

static void agg_interstitial_loadAdData(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 聚合插屏 loadAdData -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"interstitialAd:didFailWithError:"), self, adBlockError());
        safeCallDelegate2(delegate, NSSelectorFromString(@"didFailToLoadADWithPlacementID:error:"), @"", adBlockError());
    });
}

static void agg_reward_loadAdData(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 聚合激励 loadAdData -> 回调失败");
    id delegate = getDelegate(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        safeCallDelegate2(delegate, NSSelectorFromString(@"rewardedVideoAd:didFailWithError:"), self, adBlockError());
        safeCallDelegate2(delegate, NSSelectorFromString(@"didFailToLoadADWithPlacementID:error:"), @"", adBlockError());
    });
}

#pragma mark - SDK 初始化拦截 (带回调)

static void bu_sdk_setAppID(id self, SEL _cmd, id appID) {
    NSLog(@"[BlockAds] 穿山甲 setAppID 拦截");
}

static void bu_sdk_start(id self, SEL _cmd, void (^handler)(BOOL, id)) {
    NSLog(@"[BlockAds] 穿山甲 start -> 立即回调完成");
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(YES, nil);
        });
    }
}

static void csj_sdk_start(id self, SEL _cmd, id config) {
    NSLog(@"[BlockAds] CSJ startWithConfig 拦截");
}

static void gdt_sdk_register(id self, SEL _cmd, id appID) {
    NSLog(@"[BlockAds] 广点通 registerAppId 拦截");
}

static void ks_sdk_setAppId(id self, SEL _cmd, id appID) {
    NSLog(@"[BlockAds] 快手 setAppId 拦截");
}

#pragma mark - 通用空实现 (fallback)

static void stub_void(id self, SEL _cmd) {
    NSLog(@"[BlockAds] 已屏蔽: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}
static void stub_arg1(id self, SEL _cmd, id a) {
    NSLog(@"[BlockAds] 已屏蔽: -[%@ %@]", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
}

#pragma mark - dyld 延迟 Hook

static NSMutableSet *hookedClasses = nil;

// Hook 定义表: 类名 -> 方法 -> 带 delegate 回调的替换函数
static void tryHookAdClasses(void) {
    // 用 struct 数组定义所有要 hook 的方法
    struct HookEntry {
        const char *cls;
        BOOL isClass;
        SEL sel;
        IMP imp;
    };

    struct HookEntry entries[] = {
        // ---- 穿山甲 开屏 ----
        {"BUSplashAdView", NO, @selector(loadAdData), (IMP)bu_splash_loadAdData},
        {"BUSplashAdView", NO, @selector(showSplashViewInRootViewController:), (IMP)bu_splash_show},
        {"BUSplashAdView", NO, @selector(showInWindow:withBottomView:), (IMP)stub_arg1},
        {"BUSplashAd",     NO, @selector(loadAdData), (IMP)bu_splash_loadAdData},
        {"BUSplashAd",     NO, @selector(showSplashViewInRootViewController:), (IMP)bu_splash_show},
        {"CSJSplashAd",    NO, @selector(loadAdData), (IMP)bu_splash_loadAdData},
        {"CSJSplashAd",    NO, @selector(showSplashViewInRootViewController:), (IMP)bu_splash_show},
        // 穿山甲 插屏
        {"BUNativeExpressInterstitialAd", NO, @selector(loadAdData), (IMP)bu_interstitial_loadAdData},
        {"BUNativeExpressInterstitialAd", NO, @selector(showAdFromRootViewController:), (IMP)bu_interstitial_show},
        // 穿山甲 Banner
        {"BUNativeExpressBannerView", NO, @selector(loadAdData), (IMP)bu_banner_loadAdData},
        // 穿山甲 激励视频
        {"BUNativeExpressRewardedVideoAd", NO, @selector(loadAdData), (IMP)bu_reward_loadAdData},
        {"BUNativeExpressRewardedVideoAd", NO, @selector(showAdFromRootViewController:), (IMP)stub_arg1},
        // 穿山甲 全屏视频
        {"BUNativeExpressFullscreenVideoAd", NO, @selector(loadAdData), (IMP)bu_fullscreen_loadAdData},
        {"BUNativeExpressFullscreenVideoAd", NO, @selector(showAdFromRootViewController:), (IMP)stub_arg1},
        // 穿山甲 SDK 初始化
        {"BUAdSDKManager",  YES, @selector(setAppID:), (IMP)bu_sdk_setAppID},
        {"BUAdSDKManager",  YES, @selector(startWithAsyncCompletionHandler:), (IMP)bu_sdk_start},
        {"CSJAdSDKManager", YES, @selector(startWithConfig:), (IMP)csj_sdk_start},

        // ---- 广点通 ----
        {"GDTSplashAd",             NO, @selector(loadAd), (IMP)gdt_splash_loadAd},
        {"GDTSplashAd",             NO, @selector(loadAdAndShow), (IMP)gdt_splash_loadAd},
        {"GDTSplashAd",             NO, @selector(showAdInWindow:withBottomView:skipView:), (IMP)gdt_splash_show},
        {"GDTUnifiedInterstitialAd",NO, @selector(loadAd), (IMP)gdt_interstitial_loadAd},
        {"GDTUnifiedInterstitialAd",NO, @selector(presentAdFromRootViewController:), (IMP)gdt_interstitial_present},
        {"GDTUnifiedBannerView",    NO, @selector(loadAdAndShow), (IMP)gdt_banner_loadAd},
        {"GDTUnifiedNativeAd",      NO, @selector(loadAd), (IMP)gdt_native_loadAd},
        {"GDTUnifiedNativeAd",      NO, @selector(loadAdWithAdCount:), (IMP)gdt_native_loadAd},
        {"GDTRewardVideoAd",        NO, @selector(loadAd), (IMP)gdt_reward_loadAd},
        {"GDTRewardVideoAd",        NO, @selector(showAdFromRootViewController:), (IMP)stub_arg1},
        {"GDTSDKConfig",   YES, @selector(registerAppId:), (IMP)gdt_sdk_register},

        // ---- 快手 ----
        {"KSSplashAdView",    NO, @selector(loadAdData), (IMP)ks_splash_loadAdData},
        {"KSAdSplashManager", NO, @selector(loadSplashAdWithRequest:), (IMP)ks_splash_loadAdData},
        {"KSAdSplashManager", NO, @selector(showSplashAdInWindow:), (IMP)stub_arg1},
        {"KSAdSDKManager",   YES, @selector(setAppId:), (IMP)ks_sdk_setAppId},

        // ---- 百度 ----
        {"BaiduMobAdSplash",       NO, @selector(load), (IMP)bd_splash_load},
        {"BaiduMobAdSplash",       NO, @selector(show), (IMP)stub_void},
        {"BaiduMobAdInterstitial", NO, @selector(load), (IMP)bd_interstitial_load},
        {"BaiduMobAdInterstitial", NO, @selector(showFromViewController:), (IMP)stub_arg1},
        {"BaiduMobAdNative",       NO, @selector(requestNativeAds), (IMP)stub_void},

        // ---- Sigmob ----
        {"WindSplashAdView",   NO, @selector(loadAdData), (IMP)wind_splash_loadAdData},
        {"WindInterstitialAd", NO, @selector(loadAdData), (IMP)wind_interstitial_loadAdData},
        {"WindInterstitialAd", NO, @selector(showAdFromRootViewController:), (IMP)stub_arg1},
        {"WindRewardVideoAd",  NO, @selector(loadAdData), (IMP)stub_void},
        {"WindRewardVideoAd",  NO, @selector(showAdFromRootViewController:), (IMP)stub_arg1},

        // ---- AdMob ----
        {"GADInterstitialAd", YES, @selector(loadWithAdUnitID:request:completionHandler:), (IMP)gad_interstitial_load},
        {"GADRewardedAd",     YES, @selector(loadWithAdUnitID:request:completionHandler:), (IMP)gad_reward_load},
        {"GADBannerView",     NO, @selector(loadRequest:), (IMP)gad_banner_load},
        {"GADMobileAds",      NO, @selector(startWithCompletionHandler:), (IMP)gad_mobileads_start},

        // ---- AppLovin ----
        {"ALInterstitialAd", NO, @selector(show), (IMP)al_interstitial_show},
        {"ALInterstitialAd", NO, @selector(showAd:), (IMP)stub_arg1},
        {"ALAdView",         NO, @selector(loadNextAd), (IMP)stub_void},
        {"ALAdView",         NO, @selector(render:), (IMP)stub_arg1},

        // ---- GroMore ----
        {"ABUSplashAd",          NO, @selector(loadAdData), (IMP)agg_splash_loadAdData},
        {"ABUSplashAd",          NO, @selector(showSplashViewInRootViewController:), (IMP)agg_splash_show},
        {"ABUInterstitialProAd", NO, @selector(loadAdData), (IMP)agg_interstitial_loadAdData},
        {"ABUInterstitialProAd", NO, @selector(showAdFromRootViewController:), (IMP)stub_arg1},
        {"ABURewardedVideoAd",   NO, @selector(loadAdData), (IMP)agg_reward_loadAdData},
        {"ABURewardedVideoAd",   NO, @selector(showAdFromRootViewController:), (IMP)stub_arg1},

        // ---- TopOn ----
        {"ATSplashAd",       NO, @selector(loadAd), (IMP)agg_splash_loadAdData},
        {"ATSplashAd",       NO, @selector(showSplashAdInWindow:), (IMP)agg_splash_show},
        {"ATInterstitialAd", NO, @selector(loadAd), (IMP)agg_interstitial_loadAdData},
        {"ATInterstitialAd", NO, @selector(showInRootViewController:), (IMP)stub_arg1},

        // ---- TradPlus ----
        {"TradPlusSplashAd", NO, @selector(loadAd), (IMP)agg_splash_loadAdData},
    };

    int total = sizeof(entries) / sizeof(entries[0]);
    for (int i = 0; i < total; i++) {
        NSString *name = [NSString stringWithFormat:@"%s_%s",
                          entries[i].cls, sel_getName(entries[i].sel)];
        if ([hookedClasses containsObject:name]) continue;

        Class cls = objc_getClass(entries[i].cls);
        if (!cls) continue;

        Method m = entries[i].isClass
            ? class_getClassMethod(cls, entries[i].sel)
            : class_getInstanceMethod(cls, entries[i].sel);
        if (!m) continue;

        NSLog(@"[BlockAds] Hook: %c[%s %s]",
              entries[i].isClass ? '+' : '-',
              entries[i].cls, sel_getName(entries[i].sel));

        if (entries[i].isClass) {
            method_setImplementation(
                class_getInstanceMethod(object_getClass(cls), entries[i].sel),
                entries[i].imp);
        } else {
            method_setImplementation(m, entries[i].imp);
        }
        [hookedClasses addObject:name];
    }
}

static void onImageAdded(const struct mach_header *mh, intptr_t slide) {
    dispatch_async(dispatch_get_main_queue(), ^{
        tryHookAdClasses();
    });
}

#pragma mark - 定时扫描移除广告视图

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
    NSLog(@"[BlockAds] 去广告插件 v3.0 已加载");
    NSLog(@"[BlockAds] ======================================");

    hookedClasses = [NSMutableSet set];

    // 1. NSURLProtocol 网络拦截
    [NSURLProtocol registerClass:[BlockAdsURLProtocol class]];
    Class browsingCtx = NSClassFromString(@"WKBrowsingContextController");
    if (browsingCtx) {
        SEL regSel = NSSelectorFromString(@"registerSchemeForCustomProtocol:");
        if ([browsingCtx respondsToSelector:regSel]) {
            ((void(*)(id, SEL, id))objc_msgSend)(browsingCtx, regSel, @"http");
            ((void(*)(id, SEL, id))objc_msgSend)(browsingCtx, regSel, @"https");
        }
    }
    NSLog(@"[BlockAds] 网络拦截已启用");

    // 2. UIView hook
    swizzleMethod([UIView class], @selector(addSubview:),
                  (IMP)hook_addSubview, &orig_addSubview);
    swizzleMethod([UIView class], @selector(insertSubview:atIndex:),
                  (IMP)hook_insertSubview, &orig_insertSubview);
    swizzleMethod([UIView class], @selector(insertSubview:aboveSubview:),
                  (IMP)hook_insertAbove, &orig_insertAbove);

    // 3. UIViewController present hook
    swizzleMethod([UIViewController class],
                  @selector(presentViewController:animated:completion:),
                  (IMP)hook_present, &orig_present);

    // 4. WKWebView 脚本注入
    swizzleMethod([WKWebView class],
                  @selector(initWithFrame:configuration:),
                  (IMP)hook_wk_initWithFrame, &orig_wk_init);

    // 5. 立即尝试 hook 已加载的 SDK
    tryHookAdClasses();

    // 6. dyld 回调监听后续加载
    _dyld_register_func_for_add_image(onImageAdded);

    // 7. 兜底扫描
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            scanAndRemoveAdViews();
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [timer invalidate];
        });
    });

    NSLog(@"[BlockAds] 所有拦截机制已就绪 (含 delegate 回调)");
}
