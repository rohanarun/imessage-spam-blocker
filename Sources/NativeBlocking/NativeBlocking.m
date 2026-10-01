#import "NativeBlocking.h"
#import <objc/message.h>
#import <dlfcn.h>
static id facade(NSError **error) {
    dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_NOW);
    Class cls = NSClassFromString(@"CNBlockListFacade");
    id value = cls ? [[cls alloc] init] : nil;
    if (!value || ![value respondsToSelector:NSSelectorFromString(@"isHandleBlocked:")] || ![value respondsToSelector:NSSelectorFromString(@"setBlocked:forHandle:")]) {
        if (error) *error = [NSError errorWithDomain:@"QuietMessages" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Native blocking is unavailable on this version of macOS."}];
        return nil;
    }
    return value;
}
BOOL QMIsBlocked(NSString *address, NSError **error) {
    @try { id value = facade(error); return value ? ((BOOL(*)(id,SEL,id))objc_msgSend)(value, NSSelectorFromString(@"isHandleBlocked:"), address) : NO; }
    @catch (NSException *exception) { if(error) *error=[NSError errorWithDomain:@"QuietMessages" code:2 userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"Cannot read native block list."}]; return NO; }
}
BOOL QMSetBlocked(NSString *address, BOOL blocked, NSError **error) {
    @try {
        id value=facade(error); if(!value) return NO;
        ((void(*)(id,SEL,BOOL,id))objc_msgSend)(value,NSSelectorFromString(@"setBlocked:forHandle:"),blocked,address);
        BOOL actual=((BOOL(*)(id,SEL,id))objc_msgSend)(value,NSSelectorFromString(@"isHandleBlocked:"),address);
        if(actual != blocked) { if(error) *error=[NSError errorWithDomain:@"QuietMessages" code:3 userInfo:@{NSLocalizedDescriptionKey:@"macOS did not confirm the block-list change. The native blocking service may be unavailable to this app. The sender has not been marked as blocked."}];return NO; }
        return YES;
    } @catch(NSException *exception) { if(error) *error=[NSError errorWithDomain:@"QuietMessages" code:4 userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"Native blocking failed."}];return NO; }
}
