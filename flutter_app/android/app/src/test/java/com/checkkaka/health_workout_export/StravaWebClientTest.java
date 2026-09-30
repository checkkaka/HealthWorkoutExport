package com.checkkaka.health_workout_export;

import static org.junit.Assert.*;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URL;
import java.security.cert.Certificate;
import javax.net.ssl.HttpsURLConnection;
import java.io.IOException;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.junit.Test;

public class StravaWebClientTest {
    private static final URI UPLOAD = URI.create("https://www.strava.com/upload/files");

    @Test public void navigationRequiresExactTrustedHttpsOrigin() {
        for (String host : new String[] {"www.strava.com", "strava.com", "accounts.google.com", "appleid.apple.com", "facebook.com", "www.facebook.com", "m.facebook.com"}) {
            assertTrue(host, StravaWebClient.isAllowedLoginUrl("https://" + host + "/login"));
        }
        for (String url : new String[] {
            "https://evilfacebook.com", "https://facebook.com.evil.test", "https://api.strava.com",
            "http://www.strava.com", "https://www.strava.com:444", "https://user@www.strava.com",
            "javascript:alert(1)", "https://www.strava.com@evil.test", "https://evil.test/#facebook.com",
        }) assertFalse(url, StravaWebClient.isAllowedLoginUrl(url));
    }

    @Test public void cookiesRejectControlCharactersAndOversizedHeaders() {
        assertEquals("session=abc==; other=def", StravaWebClient.normalizeCookieHeader(" Cookie: session=abc==; other=def "));
        for (String value : new String[] {
            "", "session=", "bad name=value", "session=a;", "session=a;\r\nother=b", "session=a\r\nX-Evil: yes",
            "session=quoted\"", "session=with\\slash", "session=非ASCII", "session=white space", "session=comma,value",
        }) assertNull(value, StravaWebClient.normalizeCookieHeader(value));
        assertNull(StravaWebClient.normalizeCookieHeader("session=" + "x".repeat(StravaWebClient.MAX_COOKIE_BYTES)));
    }

    @Test public void csrfSupportsAttributeOrderAndRejectsHeaderInjection() {
        assertEquals("abc-_+/=", StravaWebClient.extractCSRFToken("<meta content='abc-_+/=' name='csrf-token'>"));
        assertEquals("form-token", StravaWebClient.extractCSRFToken("<input value=\"form-token\" name=\"authenticity_token\">"));
        assertNull(StravaWebClient.extractCSRFToken("<meta name='csrf-token' content='abc\r\nInjected: yes'>"));
        assertNull(StravaWebClient.extractCSRFToken("<meta name='csrf-token' content='" + "x".repeat(4097) + "'>"));
    }

    @Test public void activityLinksAndFilenamesCannotSmuggleUrlsOrMultipartHeaders() {
        assertEquals("https://www.strava.com/activities/123", StravaWebClient.activityUrl("123"));
        for (String value : new String[] {"", "../123", "https://evil.test", "123?x=y", "１２３", "1".repeat(33)}) {
            assertNull(value, StravaWebClient.activityUrl(value));
        }
        assertTrue(StravaWebClient.isSafeUploadFilename("ride.fit"));
        for (String value : new String[] {"../ride.fit", "ride.fit.exe", "ride\r\nX-Evil.fit", "ride\".fit", "a".repeat(129) + ".fit"}) {
            assertFalse(value, StravaWebClient.isSafeUploadFilename(value));
        }
    }

    @Test public void onlyVerifiedUploadEndpointAndExpectedStatusesCanSucceed() throws Exception {
        assertEquals(Boolean.FALSE, StravaWebClient.uploadResponse(response(UPLOAD, 200, "accepted")).get("isDuplicate"));
        Map<String, Object> duplicate = StravaWebClient.uploadResponse(response(UPLOAD, 422, "duplicate of <a href='/activities/42'>ride</a>"));
        assertEquals(Boolean.TRUE, duplicate.get("isDuplicate"));
        assertEquals("42", duplicate.get("remoteId"));
        assertEquals("43", StravaWebClient.uploadResponse(response(UPLOAD, 409, "Duplicate of activity 43")).get("remoteId"));
        assertFalse(StravaWebClient.uploadResponse(response(UPLOAD, 200, "duplicate of activity")).containsKey("remoteId"));
        for (int status : new int[] {301, 302, 401, 403, 429, 500}) {
            assertThrows(IOException.class, () -> StravaWebClient.uploadResponse(response(UPLOAD, status, "duplicate of activity 42")));
        }
        assertThrows(IOException.class, () -> StravaWebClient.uploadResponse(response(UPLOAD, 422, "duplicate field name")));
        for (String url : new String[] {"https://evil.test/upload/files", "https://www.strava.com/login", "http://www.strava.com/upload/files", "https://www.strava.com:444/upload/files"}) {
            assertThrows(IOException.class, () -> StravaWebClient.uploadResponse(response(URI.create(url), 200, "accepted")));
        }
    }

    @Test public void uploadUsesFixedEndpointsAndStreamsFitOnce() throws Exception {
        FakeTransport transport = new FakeTransport();
        transport.responses.add(response(URI.create("https://www.strava.com/about"), 200, "no token"));
        transport.responses.add(response(URI.create("https://www.strava.com/upload/select"), 200, "<meta name='csrf-token' content='csrf'>"));
        transport.responses.add(response(UPLOAD, 200, "accepted"));
        byte[] fit = new byte[] {14, 16, 32};
        assertEquals(Boolean.FALSE, new StravaWebClient(transport).upload(fit, "ride.fit", "session=secret").get("isDuplicate"));
        assertEquals(3, transport.requests.size());
        StravaWebClient.Request upload = transport.requests.get(2);
        assertEquals("POST", upload.method);
        assertEquals(UPLOAD, upload.url);
        assertSame(fit, upload.fit);
        assertEquals("session=secret", upload.headers.get("Cookie"));
        assertEquals("csrf", upload.headers.get("X-CSRF-Token"));
        String prefix = new String(upload.prefix, StandardCharsets.UTF_8);
        assertTrue(prefix.contains("name=\"authenticity_token\"\r\n\r\ncsrf\r\n"));
        assertTrue(prefix.contains("filename=\"ride.fit\""));
    }

    @Test public void redirectOrWrongFinalOriginStopsBeforeUploading() {
        for (StravaWebClient.Response response : new StravaWebClient.Response[] {
            response(URI.create("https://www.strava.com/about"), 302, "redirect"),
            response(URI.create("https://evil.test/about"), 200, "<meta name='csrf-token' content='csrf'>"),
        }) {
            FakeTransport transport = new FakeTransport();
            transport.responses.add(response);
            assertThrows(IOException.class, () -> new StravaWebClient(transport).upload(new byte[] {1}, "ride.fit", "session=secret"));
            assertEquals(1, transport.requests.size());
        }
    }

    @Test public void invalidInputsNeverReachTransport() {
        FakeTransport transport = new FakeTransport();
        StravaWebClient client = new StravaWebClient(transport);
        assertThrows(IOException.class, () -> client.upload(new byte[] {1}, "../ride.fit", "session=secret"));
        assertThrows(IOException.class, () -> client.upload(new byte[0], "ride.fit", "session=secret"));
        assertThrows(IOException.class, () -> client.upload(new byte[] {1}, "ride.fit", "session=a\r\nInjected: yes"));
        assertEquals(0, transport.requests.size());
    }

    @Test public void responseBoundsApplyEvenWithoutContentLength() throws Exception {
        byte[] exact = new byte[StravaWebClient.MAX_RESPONSE_BYTES];
        assertArrayEquals(exact, StravaWebClient.readBounded(new ByteArrayInputStream(exact), -1));
        assertThrows(IOException.class, () -> StravaWebClient.readBounded(new ByteArrayInputStream(new byte[1]), StravaWebClient.MAX_RESPONSE_BYTES + 1L));
        assertThrows(IOException.class, () -> StravaWebClient.readBounded(new ByteArrayInputStream(new byte[StravaWebClient.MAX_RESPONSE_BYTES + 1]), -1));
    }

    @Test public void cancellationReachesTransport() {
        FakeTransport transport = new FakeTransport();
        new StravaWebClient(transport).cancel();
        assertTrue(transport.cancelled);
    }

    @Test public void deletionOnlyAcceptsKnownSameOriginRedirects() {
        URI activity = URI.create("https://www.strava.com/activities/42");
        for (String location : new String[] {"/athlete/training", "https://www.strava.com/dashboard"}) {
            assertTrue(StravaWebClient.isSuccessfulDeletion(new StravaWebClient.Response(activity, 302, new byte[0], location), "42"));
        }
        for (String location : new String[] {"/login", "https://evil.test/dashboard", "//evil.test/athlete/training", "/activities/42", "https://www.strava.com:444/dashboard"}) {
            assertFalse(StravaWebClient.isSuccessfulDeletion(new StravaWebClient.Response(activity, 302, new byte[0], location), "42"));
        }
        assertTrue(StravaWebClient.isSuccessfulDeletion(response(activity, 404, "missing"), "42"));
        assertFalse(StravaWebClient.isSuccessfulDeletion(response(activity, 403, "not found"), "42"));
        assertFalse(StravaWebClient.isSuccessfulDeletion(response(activity, 200, "please log in"), "42"));
        assertFalse(StravaWebClient.isSuccessfulDeletion(response(URI.create("https://evil.test/activities/42"), 404, "missing"), "42"));
    }

    @Test public void deletionEncodesTokenAndSubmitsOnePlainFormWithoutXhr() throws Exception {
        FakeTransport transport = new FakeTransport();
        URI activity = URI.create("https://www.strava.com/activities/42");
        transport.responses.add(response(activity, 200, "<meta name='csrf-param' content='csrf_param'><meta name='csrf-token' content='a+/='>"));
        transport.responses.add(new StravaWebClient.Response(activity, 302, new byte[0], "/athlete/training"));
        new StravaWebClient(transport).deleteActivity("42", "session=secret");
        assertEquals(2, transport.requests.size());
        StravaWebClient.Request deletion = transport.requests.get(1);
        assertEquals("POST", deletion.method);
        assertFalse(deletion.headers.containsKey("X-Requested-With"));
        assertFalse(deletion.headers.containsKey("X-CSRF-Token"));
        assertEquals("_method=delete&csrf_param=a%2B%2F%3D", new String(deletion.fit, StandardCharsets.UTF_8));
    }

    @Test public void deletionDoesNotReplayRejectedMutationAndMissingActivityIsAlreadyDone() throws Exception {
        URI activity = URI.create("https://www.strava.com/activities/42");
        FakeTransport rejected = new FakeTransport();
        rejected.responses.add(response(activity, 200, "<meta name='csrf-token' content='csrf'>"));
        rejected.responses.add(response(activity, 500, "failure"));
        assertThrows(IOException.class, () -> new StravaWebClient(rejected).deleteActivity("42", "session=secret"));
        assertEquals(2, rejected.requests.size());
        FakeTransport missing = new FakeTransport();
        missing.responses.add(response(activity, 404, "missing"));
        new StravaWebClient(missing).deleteActivity("42", "session=secret");
        assertEquals(1, missing.requests.size());
        assertNull(StravaWebClient.extractCSRFPair("<meta name='csrf-param' content='_method'><meta name='csrf-token' content='delete'>"));
    }

    @Test public void listQueryUsesBoundedUtcCalendarDatesAndKnownEndpoint() throws Exception {
        long start = java.time.Instant.parse("2026-09-30T00:00:00Z").toEpochMilli();
        long end = start + 86_400_000;
        URI url = StravaWebClient.activityPageUrl(2, start, end);
        assertEquals("https://www.strava.com/athlete/training_activities?start_date=09%2F29%2F2026&end_date=10%2F02%2F2026&page=2&new_activity_only=false", url.toString());
        assertNull(StravaWebClient.activityPageUrl(0, start, end));
        assertNull(StravaWebClient.activityPageUrl(201, start, end));
        assertNull(StravaWebClient.activityPageUrl(1, end, start));
        assertNull(StravaWebClient.activityPageUrl(1, Long.MIN_VALUE, Long.MAX_VALUE));
        FakeTransport transport = new FakeTransport();
        transport.responses.add(response(url, 200, "{\"models\":[]}"));
        assertEquals("{\"models\":[]}", new StravaWebClient(transport).listActivityPage(2, start, end, "session=secret").text());
        assertEquals(url, transport.requests.get(0).url);
    }

    @Test public void productionTransportDisablesRedirectsAndClosesConnection() throws Exception {
        FakeConnection connection = new FakeConnection(new URL("https://www.strava.com/athlete/training_activities"), 302);
        StravaWebClient client = new StravaWebClient(new StravaWebClient.HttpsTransport(url -> connection));
        assertThrows(IOException.class, () -> client.probe("session=secret"));
        assertFalse(connection.getInstanceFollowRedirects());
        assertFalse(connection.getUseCaches());
        assertEquals(30_000, connection.getConnectTimeout());
        assertEquals(30_000, connection.getReadTimeout());
        assertEquals("session=secret", connection.getRequestProperty("Cookie"));
        assertTrue(connection.disconnected);
    }

    @Test public void cancelledProductionTransportCannotStartAnotherRequest() {
        boolean[] opened = {false};
        StravaWebClient client = new StravaWebClient(new StravaWebClient.HttpsTransport(url -> {
            opened[0] = true;
            throw new IOException("Unexpected connection");
        }));
        client.cancel();
        assertThrows(IOException.class, () -> client.probe("session=secret"));
        assertFalse(opened[0]);
    }

    private static final class FakeConnection extends HttpsURLConnection {
        final int status;
        boolean disconnected;
        FakeConnection(URL url, int status) { super(url); this.status = status; }
        @Override public int getResponseCode() { return status; }
        @Override public InputStream getInputStream() { return new ByteArrayInputStream(new byte[0]); }
        @Override public OutputStream getOutputStream() { return new ByteArrayOutputStream(); }
        @Override public String getCipherSuite() { return "fixture"; }
        @Override public Certificate[] getLocalCertificates() { return null; }
        @Override public Certificate[] getServerCertificates() { return new Certificate[0]; }
        @Override public void connect() {}
        @Override public void disconnect() { disconnected = true; }
        @Override public boolean usingProxy() { return false; }
    }

    private static StravaWebClient.Response response(URI uri, int status, String body) {
        return new StravaWebClient.Response(uri, status, body.getBytes(StandardCharsets.UTF_8));
    }

    private static final class FakeTransport implements StravaWebClient.Transport {
        final List<StravaWebClient.Request> requests = new ArrayList<>();
        final List<StravaWebClient.Response> responses = new ArrayList<>();
        boolean cancelled;
        public StravaWebClient.Response execute(StravaWebClient.Request request) throws IOException {
            requests.add(request);
            if (responses.isEmpty()) throw new IOException("Missing fixture");
            return responses.remove(0);
        }
        public void cancel() { cancelled = true; }
    }
}
