// SCDynamicStore exists on iOS but the SDK marks it unavailable; alias the real symbols.
#import <SystemConfiguration/SystemConfiguration.h>

typedef void (*AHSStoreCallback)(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info);

extern SCDynamicStoreRef AHSStoreCreate(CFAllocatorRef, CFStringRef, AHSStoreCallback, SCDynamicStoreContext *) __asm__("_SCDynamicStoreCreate");
extern CFArrayRef AHSStoreCopyKeyList(SCDynamicStoreRef, CFStringRef) __asm__("_SCDynamicStoreCopyKeyList");
extern CFPropertyListRef AHSStoreCopyValue(SCDynamicStoreRef, CFStringRef) __asm__("_SCDynamicStoreCopyValue");
extern Boolean AHSStoreSetNotificationKeys(SCDynamicStoreRef, CFArrayRef, CFArrayRef) __asm__("_SCDynamicStoreSetNotificationKeys");
extern Boolean AHSStoreSetDispatchQueue(SCDynamicStoreRef, dispatch_queue_t) __asm__("_SCDynamicStoreSetDispatchQueue");
