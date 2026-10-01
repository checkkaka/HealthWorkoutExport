package com.checkkaka.health_workout_export;

import static org.junit.Assert.*;
import org.junit.Test;

public class StravaOAuthSecurityTest {
    private static final String STATE = "012345678901234567890123456789";
    @Test public void stateIsRandomUrlSafeAndAddedOnce() {
        String first = StravaOAuthSecurity.makeState();
        assertTrue(first.matches("[A-Za-z0-9_-]{43}"));
        assertNotEquals(first, StravaOAuthSecurity.makeState());
        assertTrue(StravaOAuthSecurity.authorizationUrl("https://www.strava.com/oauth/mobile/authorize?client_id=1", STATE).endsWith("&state=" + STATE));
        assertThrows(IllegalArgumentException.class, () -> StravaOAuthSecurity.authorizationUrl("https://www.strava.com/oauth/mobile/authorize?state=attacker", STATE));
        assertThrows(IllegalArgumentException.class, () -> StravaOAuthSecurity.authorizationUrl("https://www.strava.com/oauth/mobile/authorize?st%61te=attacker", STATE));
    }
    @Test public void authorizationRejectsSpoofedOriginsPathsAndFragments() {
        for (String url : new String[]{"http://www.strava.com/oauth/mobile/authorize", "https://evil.test/oauth/mobile/authorize", "https://user@www.strava.com/oauth/mobile/authorize", "https://www.strava.com:444/oauth/mobile/authorize", "https://www.strava.com/oauth/mobile/authorize#x", "https://www.strava.com/oauth/mobile/%61uthorize"}) {
            assertThrows(IllegalArgumentException.class, () -> StravaOAuthSecurity.authorizationUrl(url, STATE));
        }
    }
    @Test public void callbackRequiresUniqueStateAndCodeWithoutAuthorityAmbiguity() throws Exception {
        String valid = "healthworkoutexport://localhost/callback?state=" + STATE + "&code=abc";
        assertEquals("abc", StravaOAuthSecurity.callbackCode(valid, STATE));
        for (String url : new String[]{valid + "&code=extra", valid + "&state=" + STATE, valid + "#fragment", valid.replace("localhost", "user@localhost"), valid.replace("localhost", "localhost:443"), valid.replace("localhost", "evil.test"), valid.replace(STATE, "wrong")}) {
            assertThrows(StravaOAuthSecurity.OAuthFailure.class, () -> StravaOAuthSecurity.callbackCode(url, STATE));
        }
        StravaOAuthSecurity.OAuthFailure denied = assertThrows(StravaOAuthSecurity.OAuthFailure.class, () -> StravaOAuthSecurity.callbackCode("healthworkoutexport://localhost/callback?state=" + STATE + "&error=access_denied", STATE));
        assertEquals("oauth_cancelled", denied.code);
    }
}
