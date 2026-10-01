package com.checkkaka.health_workout_export;

import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;

/** Pure OAuth origin/state rules. Never logs or persists authorization codes or callbacks. */
public final class StravaOAuthSecurity {
    private StravaOAuthSecurity() {}
    public static String makeState() {
        byte[] random = new byte[32]; new SecureRandom().nextBytes(random);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(random);
    }

    public static String authorizationUrl(String raw, String state) {
        try {
            URI uri = new URI(raw);
            if (!"https".equalsIgnoreCase(uri.getScheme()) || !"www.strava.com".equalsIgnoreCase(uri.getHost())
                || !"/oauth/mobile/authorize".equals(uri.getRawPath()) || uri.getRawUserInfo() != null
                || uri.getPort() != -1 && uri.getPort() != 443 || uri.getRawFragment() != null
                || !values(uri, "state").isEmpty() || state == null || !state.matches("[A-Za-z0-9_-]{20,128}")) {
                throw new IllegalArgumentException("Invalid OAuth request");
            }
            return raw + (uri.getRawQuery() == null ? "?" : "&") + "state=" + state;
        } catch (Exception error) { throw new IllegalArgumentException("Invalid OAuth request"); }
    }

    public static String callbackCode(String raw, String expectedState) throws OAuthFailure {
        try {
            URI uri = new URI(raw);
            List<String> states = values(uri, "state");
            if (!"healthworkoutexport".equalsIgnoreCase(uri.getScheme()) || !"localhost".equalsIgnoreCase(uri.getHost())
                || !"/callback".equals(uri.getRawPath()) || uri.getRawUserInfo() != null || uri.getPort() != -1
                || uri.getRawFragment() != null || states.size() != 1 || expectedState == null
                || !MessageDigest.isEqual(states.get(0).getBytes(StandardCharsets.UTF_8), expectedState.getBytes(StandardCharsets.UTF_8))) {
                throw new OAuthFailure("oauth_invalid_callback");
            }
            List<String> errors = values(uri, "error");
            if (!errors.isEmpty()) throw new OAuthFailure(errors.size() == 1 && "access_denied".equals(errors.get(0)) ? "oauth_cancelled" : "oauth_failed");
            List<String> codes = values(uri, "code");
            if (codes.size() != 1 || codes.get(0).isEmpty() || codes.get(0).length() > 4096) throw new OAuthFailure("oauth_invalid_callback");
            return codes.get(0);
        } catch (OAuthFailure error) { throw error; }
        catch (Exception error) { throw new OAuthFailure("oauth_invalid_callback"); }
    }

    private static List<String> values(URI uri, String name) throws Exception {
        List<String> values = new ArrayList<>();
        String query = uri.getRawQuery();
        if (query == null) return values;
        for (String pair : query.split("&", -1)) {
            int index = pair.indexOf('=');
            String key = URLDecoder.decode(index < 0 ? pair : pair.substring(0, index), "UTF-8");
            if (name.equals(key)) values.add(index < 0 ? "" : URLDecoder.decode(pair.substring(index + 1), "UTF-8"));
        }
        return values;
    }

    public static final class OAuthFailure extends Exception {
        private static final long serialVersionUID = 1L;
        public final String code;
        OAuthFailure(String code) { super("OAuth callback rejected"); this.code = code; }
    }
}
