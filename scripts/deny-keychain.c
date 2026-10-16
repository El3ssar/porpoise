// Verification tripwire: inject into tests/review apps to prove they make no Keychain calls.
// clang -framework Security -dynamiclib scripts/deny-keychain.c -o /tmp/porpoise-deny-keychain.dylib
// PORPOISE_DENY_KEYCHAIN_DYLIB=/tmp/porpoise-deny-keychain.dylib ./scripts/test-with-watchdog.sh --enable-code-coverage
// SecRandomCopyBytes is deliberately allowed (OAuth PKCE uses secure random bytes).
#include <Security/Security.h>
#include <unistd.h>
#include <stdio.h>

__attribute__((constructor)) static void active(void) {
    char message[100];
    int count = snprintf(message, sizeof(message), "Keychain denial tripwire active pid=%d\n", getpid());
    write(STDERR_FILENO, message, count);
}

static OSStatus denied(void) {
    static const char message[] = "ERROR: isolated process attempted a Keychain operation\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(99);
}

#define INTERPOSE(name) \
    __attribute__((used)) static struct { const void *replacement; const void *original; } \
    interpose_##name __attribute__((section("__DATA,__interpose"))) = { (const void *)denied, (const void *)name }

INTERPOSE(SecItemCopyMatching);
INTERPOSE(SecItemAdd);
INTERPOSE(SecItemUpdate);
INTERPOSE(SecItemDelete);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
INTERPOSE(SecKeychainCreate);
INTERPOSE(SecKeychainDelete);
#pragma clang diagnostic pop
