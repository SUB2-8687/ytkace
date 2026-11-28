#import "Localization.h"
#import "Preferences.h"
#import "../UI/Assets.h"

#import <UIKit/UIKit.h>

NSString * const YTKACELanguageKey = @"YTKACE.Preference.Language";

NSArray<NSString *> *YTKACEAvailableLanguages(void) {
    // sideload IPA 빌드는 en/ko 외 언어팩을 지우므로(Scripts/strip-extras.sh),
    // 실제로 번들에 들어 있는 언어만 목록에 노출한다.
    static NSArray<NSString *> *languages;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *all = @[@"system", @"en", @"ar", @"ckb", @"de", @"es", @"fr", @"it",
                                     @"ja", @"ko", @"pl", @"pt-BR", @"ru", @"tr", @"vi", @"zh-Hans", @"zh-Hant"];
        NSBundle *bundle = YTKACEAssetsBundle();
        if (bundle == nil) {
            languages = all;
            return;
        }
        NSMutableArray<NSString *> *present = [NSMutableArray array];
        for (NSString *code in all) {
            if ([code isEqualToString:@"system"] || [code isEqualToString:@"en"]) {
                [present addObject:code];
                continue;
            }
            NSString *directory = [bundle.resourcePath stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@.lproj", code]];
            if ([NSFileManager.defaultManager fileExistsAtPath:directory]) [present addObject:code];
        }
        languages = [present copy];
    });
    return languages;
}

NSString *YTKACELanguageDisplayName(NSString *code) {
    if ([code isEqualToString:@"system"]) return @"System";
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            @"en": @"English",
            @"ar": @"العربية",
            @"ckb": @"کوردی",
            @"de": @"Deutsch",
            @"es": @"Español",
            @"fr": @"Français",
            @"it": @"Italiano",
            @"ja": @"日本語",
            @"ko": @"한국어",
            @"pl": @"Polski",
            @"pt-BR": @"Português (Brasil)",
            @"ru": @"Русский",
            @"tr": @"Türkçe",
            @"vi": @"Tiếng Việt",
            @"zh-Hans": @"简体中文",
            @"zh-Hant": @"繁體中文"
        };
    });
    return names[code] ?: code;
}

static NSString *YTKACEPreferredLanguage(void) {
    id stored = YTKACEPreferenceObject(YTKACELanguageKey);
    NSString *choice = [stored isKindOfClass:NSString.class] ? stored : @"system";
    if (![choice isEqualToString:@"system"]) return choice;

    NSArray<NSString *> *available = YTKACEAvailableLanguages();
    for (NSString *preferred in NSLocale.preferredLanguages) {
        NSString *code = preferred;
        if ([code hasPrefix:@"zh-Hans"] || [code hasPrefix:@"zh-CN"] ||
            [code hasPrefix:@"zh-SG"]) {
            return @"zh-Hans";
        }
        if ([code hasPrefix:@"zh"]) return @"zh-Hant";
        if ([code hasPrefix:@"pt"]) return @"pt-BR";
        NSRange separator = [code rangeOfString:@"-"];
        if (separator.location != NSNotFound) {
            code = [code substringToIndex:separator.location];
        }
        if ([available containsObject:code]) return code;
    }
    return @"en";
}

static NSDictionary<NSString *, NSString *> *YTKACEStringsForLanguage(NSString *code) {
    NSBundle *bundle = YTKACEAssetsBundle();
    if (bundle == nil) return nil;
    NSString *path = [bundle pathForResource:@"Localizable"
                                      ofType:@"strings"
                                 inDirectory:nil
                             forLocalization:code];
    if (path == nil) {
        path = [bundle.resourcePath stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.lproj/Localizable.strings", code]];
    }
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

static NSDictionary<NSString *, NSString *> *YTKACEActiveStrings;
static NSString *YTKACEActiveLanguage;

void YTKACEResetLocalizationCache(void) {
    YTKACEActiveStrings = nil;
    YTKACEActiveLanguage = nil;
}

NSString *YTKACELocalized(NSString *key) {
    if (key.length == 0) return key;
    NSString *language = YTKACEPreferredLanguage();
    if (![language isEqualToString:YTKACEActiveLanguage]) {
        YTKACEActiveLanguage = language;
        YTKACEActiveStrings = YTKACEStringsForLanguage(language);
    }
    NSString *value = YTKACEActiveStrings[key];
    return value.length != 0 ? value : key;
}
