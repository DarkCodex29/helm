"""HTTPS-only transport for every outbound request the notifier makes.

urllib's default opener follows redirects to any scheme, so an https endpoint
that answers 302 -> http:// would make the next request (carrying a bearer
token) travel in clear text. This opener refuses any non-https redirect.
"""
import urllib.request


class HttpsOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not str(newurl).lower().startswith("https://"):
            raise RuntimeError("refusing non-https redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = urllib.request.build_opener(HttpsOnlyRedirect())


def urlopen(req, timeout=None):
    return _OPENER.open(req, timeout=timeout)  # noqa: S310 (callers use https URLs)
