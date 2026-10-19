// Exposes libwebp's encoder to Swift. libwebp is linked statically by build.sh,
// so the built app doesn't depend on Homebrew at runtime.
#include <webp/encode.h>
