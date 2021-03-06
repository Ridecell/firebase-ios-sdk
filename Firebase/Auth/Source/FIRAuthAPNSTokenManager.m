/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Private/FIRAuthAPNSTokenManager.h"

#import "FIRLogger.h"
#import "Private/FIRAuthAPNSToken.h"
#import "FIRAuthGlobalWorkQueue.h"

NS_ASSUME_NONNULL_BEGIN

/** @var kRegistrationTimeout
    @brief Timeout for registration for remote notification.
    @remarks Once we start to handle `application:didFailToRegisterForRemoteNotificationsWithError:`
        we probably don't have to use timeout at all.
 */
static const NSTimeInterval kRegistrationTimeout = 5;

/** @var kLegacyRegistrationTimeout
    @brief Timeout for registration for remote notification on iOS 7.
 */
static const NSTimeInterval kLegacyRegistrationTimeout = 30;

@implementation FIRAuthAPNSTokenManager {
  /** @var _application
      @brief The @c UIApplication to request the token from.
   */
  UIApplication *_application;

  /** @var _pendingCallbacks
      @brief The list of all pending callbacks for the APNs token.
   */
  NSMutableArray<FIRAuthAPNSTokenCallback> *_pendingCallbacks;
}

- (instancetype)initWithApplication:(UIApplication *)application {
  self = [super init];
  if (self) {
    _application = application;
    _timeout = [_application respondsToSelector:@selector(registerForRemoteNotifications)] ?
        kRegistrationTimeout : kLegacyRegistrationTimeout;
  }
  return self;
}

- (void)getTokenWithCallback:(FIRAuthAPNSTokenCallback)callback {
  if (_token) {
    callback(_token);
    return;
  }
  if (_pendingCallbacks) {
    [_pendingCallbacks addObject:callback];
    return;
  }
  _pendingCallbacks =
      [[NSMutableArray<FIRAuthAPNSTokenCallback> alloc] initWithObjects:callback, nil];
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([_application respondsToSelector:@selector(registerForRemoteNotifications)]) {
      [_application registerForRemoteNotifications];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      [_application registerForRemoteNotificationTypes:UIRemoteNotificationTypeAlert];
#pragma clang diagnostic pop
    }
  });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_timeout * NSEC_PER_SEC)),
                               FIRAuthGlobalWorkQueue(), ^{
    [self callBack];
  });
}

- (void)setToken:(nullable FIRAuthAPNSToken *)token {
  if (!token) {
    _token = nil;
    return;
  }
  if (token.type == FIRAuthAPNSTokenTypeUnknown) {
    static FIRAuthAPNSTokenType detectedTokenType = FIRAuthAPNSTokenTypeUnknown;
    if (detectedTokenType == FIRAuthAPNSTokenTypeUnknown) {
      detectedTokenType =
          [[self class] isProductionApp] ? FIRAuthAPNSTokenTypeProd : FIRAuthAPNSTokenTypeSandbox;
    }
    token = [[FIRAuthAPNSToken alloc] initWithData:token.data type:detectedTokenType];
  }
  _token = token;
  [self callBack];
}

#pragma mark - Internal methods

/** @fn callBack
    @brief Calls back all pending callbacks with the current APNs token, if one is available.
 */
- (void)callBack {
  if (!_pendingCallbacks) {
    return;
  }
  NSArray<FIRAuthAPNSTokenCallback> *allCallbacks = _pendingCallbacks;
  _pendingCallbacks = nil;
  for (FIRAuthAPNSTokenCallback callback in allCallbacks) {
    callback(_token);
  }
};

/** @fn isProductionApp
    @brief Whether or not the app has production (versus sandbox) provisioning profile.
    @remarks This method is adapted from @c FIRInstanceID .
 */
+ (BOOL)isProductionApp {
  const BOOL defaultAppTypeProd = YES;

  NSError *error = nil;

  Class envClass = NSClassFromString(@"FIRAppEnvironmentUtil");
  SEL isSimulatorSelector = NSSelectorFromString(@"isSimulator");
  if ([envClass respondsToSelector:isSimulatorSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if ([envClass performSelector:isSimulatorSelector]) {
#pragma clang diagnostic pop
      FIRLogWarning(kFIRLoggerAuth, @"I-AUT000006",
                    @"Assuming prod APNs token type on simulator.");
      return defaultAppTypeProd;
    }
  }

  NSString *path = [[[NSBundle mainBundle] bundlePath]
      stringByAppendingPathComponent:@"embedded.mobileprovision"];

  // Apps distributed via AppStore or TestFlight use the Production APNS certificates.
  SEL isFromAppStoreSelector = NSSelectorFromString(@"isFromAppStore");
  if ([envClass respondsToSelector:isFromAppStoreSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if ([envClass performSelector:isFromAppStoreSelector]) {
#pragma clang diagnostic pop
      return defaultAppTypeProd;
    }
  }

  SEL isAppStoreReceiptSandboxSelector = NSSelectorFromString(@"isAppStoreReceiptSandbox");
  if ([envClass respondsToSelector:isAppStoreReceiptSandboxSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if ([envClass performSelector:isAppStoreReceiptSandboxSelector] && !path.length) {
#pragma clang diagnostic pop
      // Distributed via TestFlight
      return defaultAppTypeProd;
    }
  }

  NSMutableData *profileData = [NSMutableData dataWithContentsOfFile:path options:0 error:&error];

  if (!profileData.length || error) {
    FIRLogWarning(kFIRLoggerAuth, @"I-AUT000007",
                  @"Error while reading embedded mobileprovision %@", error);
    return defaultAppTypeProd;
  }

  // The "embedded.mobileprovision" sometimes contains characters with value 0, which signals the
  // end of a c-string and halts the ASCII parser, or with value > 127, which violates strict 7-bit
  // ASCII. Replace any 0s or invalid characters in the input.
  uint8_t *profileBytes = (uint8_t *)profileData.bytes;
  for (int i = 0; i < profileData.length; i++) {
    uint8_t currentByte = profileBytes[i];
    if (!currentByte || currentByte > 127) {
      profileBytes[i] = '.';
    }
  }

  NSString *embeddedProfile = [[NSString alloc] initWithBytesNoCopy:profileBytes
                                                             length:profileData.length
                                                           encoding:NSASCIIStringEncoding
                                                       freeWhenDone:NO];

  if (error || !embeddedProfile.length) {
    FIRLogWarning(kFIRLoggerAuth, @"I-AUT000008",
                  @"Error while reading embedded mobileprovision %@", error);
    return defaultAppTypeProd;
  }

  NSScanner *scanner = [NSScanner scannerWithString:embeddedProfile];
  NSString *plistContents;
  if ([scanner scanUpToString:@"<plist" intoString:nil]) {
    if ([scanner scanUpToString:@"</plist>" intoString:&plistContents]) {
      plistContents = [plistContents stringByAppendingString:@"</plist>"];
    }
  }

  if (!plistContents.length) {
    return defaultAppTypeProd;
  }

  NSData *data = [plistContents dataUsingEncoding:NSUTF8StringEncoding];
  if (!data.length) {
    FIRLogWarning(kFIRLoggerAuth, @"I-AUT000009",
                  @"Couldn't read plist fetched from embedded mobileprovision");
    return defaultAppTypeProd;
  }

  NSError *plistMapError;
  id plistData = [NSPropertyListSerialization propertyListWithData:data
                                                           options:NSPropertyListImmutable
                                                            format:nil
                                                             error:&plistMapError];
  if (plistMapError || ![plistData isKindOfClass:[NSDictionary class]]) {
    FIRLogWarning(kFIRLoggerAuth, @"I-AUT000010",
                  @"Error while converting assumed plist to dict %@",
                  plistMapError.localizedDescription);
    return defaultAppTypeProd;
  }
  NSDictionary *plistMap = (NSDictionary *)plistData;

  if ([plistMap valueForKeyPath:@"ProvisionedDevices"]) {
    FIRLogInfo(kFIRLoggerAuth, @"I-AUT000011",
               @"Provisioning profile has specifically provisioned devices, "
               @"most likely a Dev profile.");
  }

  NSString *apsEnvironment = [plistMap valueForKeyPath:@"Entitlements.aps-environment"];
  FIRLogDebug(kFIRLoggerAuth, @"I-AUT000012",
              @"APNS Environment in profile: %@", apsEnvironment);

  // No aps-environment in the profile.
  if (!apsEnvironment.length) {
    FIRLogWarning(kFIRLoggerAuth, @"I-AUT000013",
                  @"No aps-environment set. If testing on a device APNS is not "
                  @"correctly configured. Please recheck your provisioning profiles.");
    return defaultAppTypeProd;
  }

  if ([apsEnvironment isEqualToString:@"development"]) {
    return NO;
  }

  return defaultAppTypeProd;
}

@end

NS_ASSUME_NONNULL_END
