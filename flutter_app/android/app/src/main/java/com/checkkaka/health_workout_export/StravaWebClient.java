package com.checkkaka.health_workout_export;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.net.URLEncoder;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import javax.net.ssl.HttpsURLConnection;

/** Fixed-origin web upload boundary. Credentials and FIT bytes never cross a redirect. */
public final class StravaWebClient {
    public static final int MAX_COOKIE_BYTES = 16_384;
    public static final int MAX_FIT_BYTES = 64 * 1024 * 1024;
    public static final int MAX_RESPONSE_BYTES = 4 * 1024 * 1024;
    private static final String ORIGIN = "https://www.strava.com";
    private static final Set<String> LOGIN_HOSTS = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
        "strava.com", "www.strava.com", "accounts.google.com", "appleid.apple.com",
        "facebook.com", "www.facebook.com", "m.facebook.com"
    )));
    private static final Set<String> REQUEST_PATHS = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
        "/about", "/upload/select", "/upload/files", "/athlete/training_activities"
    )));
    private static final Pattern COOKIE_NAME = Pattern.compile("[!#$%&'*+.^_`|~0-9A-Za-z-]+");
    private static final Pattern TAG = Pattern.compile("<(?:meta|input)\\b[^>]*>", Pattern.CASE_INSENSITIVE);
    private static final Pattern ATTRIBUTE = Pattern.compile(
        "([a-zA-Z_-]+)\\s*=\\s*([\"'])(.*?)\\2", Pattern.CASE_INSENSITIVE | Pattern.DOTALL
    );
    private static final Pattern DUPLICATE_ID = Pattern.compile(
        "duplicate of activity ([0-9]+)|/activities/([0-9]+)", Pattern.CASE_INSENSITIVE
    );
    private static final Pattern DUPLICATE = Pattern.compile(
        "duplicate of(?: activity|\\s*<a)", Pattern.CASE_INSENSITIVE
    );
    private final Transport transport;

    public StravaWebClient() { this(new HttpsTransport()); }
    StravaWebClient(Transport transport) { this.transport = transport; }

    public void cancel() { transport.cancel(); }

    public Response probe(String cookie) throws IOException {
        return execute(request(
            "/athlete/training_activities?start_date=01%2F01%2F2010&end_date=12%2F31%2F2035&page=1&new_activity_only=false",
            "GET", cookie, Collections.singletonMap("Accept", "application/json"), null, null, null
        ));
    }

    public Map<String, Object> readActivitySpeedData(String remoteId, String cookie) throws IOException {
        String rawUrl = activityUrl(remoteId);
        if (rawUrl == null) throw new IOException("Invalid activity ID");
        URI url = URI.create(rawUrl);
        Response page = execute(request(url.getPath(), "GET", cookie,
            Collections.singletonMap("Accept", "text/html"), null, null, null));
        if (page.statusCode == 404) return null;
        if (page.statusCode != 200) throw new IOException("Web activity unavailable");
        Map<String, Object> payload = new HashMap<>();
        payload.put("pageHtml", page.text());
        payload.put("streamsJson", null);
        try {
            Map<String, String> headers = new LinkedHashMap<>();
            headers.put("Accept", "application/json");
            headers.put("Referer", rawUrl);
            Response streams = execute(request(url.getPath() + "/streams?stream_types%5B%5D=velocity_smooth",
                "GET", cookie, headers, null, null, null));
            if (streams.statusCode == 200) payload.put("streamsJson", streams.text());
        } catch (IOException error) {
            if (Thread.currentThread().isInterrupted()) throw error;
            // Optional streams may not exist. Keep the valid page for bounded Rust parsing.
        }
        return payload;
    }

    public Response listActivityPage(int page, long afterMs, long beforeMs, String cookie) throws IOException {
        URI url = activityPageUrl(page, afterMs, beforeMs);
        if (url == null) throw new IOException("Invalid activity page");
        return execute(request(url.getRawPath() + "?" + url.getRawQuery(), "GET", cookie,
            Collections.singletonMap("Accept", "application/json"), null, null, null));
    }

    public static URI activityPageUrl(int page, long afterMs, long beforeMs) {
        if (page < 1 || page > 200 || afterMs >= beforeMs || afterMs < -2_208_988_800_000L
            || beforeMs > 7_258_118_400_000L) return null;
        DateTimeFormatter formatter = DateTimeFormatter.ofPattern("MM/dd/yyyy", Locale.ROOT).withZone(ZoneOffset.UTC);
        // Widen date-only filters so the athlete's timezone cannot omit edge-day records.
        String start = formatter.format(Instant.ofEpochMilli(afterMs).minusSeconds(86_400)).replace("/", "%2F");
        String end = formatter.format(Instant.ofEpochMilli(beforeMs).plusSeconds(86_400)).replace("/", "%2F");
        return URI.create(ORIGIN + "/athlete/training_activities?start_date=" + start + "&end_date=" + end
            + "&page=" + page + "&new_activity_only=false");
    }

    public void deleteActivity(String remoteId, String cookie) throws IOException {
        String rawUrl = activityUrl(remoteId);
        if (rawUrl == null) throw new IOException("Invalid activity ID");
        URI url = URI.create(rawUrl);
        Csrf csrf = null;
        for (String path : new String[] {url.getPath(), "/about", "/upload/select"}) {
            Response response = execute(request(path, "GET", cookie,
                Collections.singletonMap("Accept", "text/html"), null, null, null));
            if (response.statusCode == 404 && path.equals(url.getPath())) return;
            if (response.statusCode == 401 || response.statusCode == 403) throw new IOException("Web session expired");
            if (response.statusCode == 200) csrf = extractCSRFPair(response.text());
            if (csrf != null) break;
        }
        if (csrf == null) throw new IOException("Unable to verify web session");
        String form = "_method=delete&" + URLEncoder.encode(csrf.parameter, "UTF-8")
            + "=" + URLEncoder.encode(csrf.token, "UTF-8");
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Content-Type", "application/x-www-form-urlencoded");
        headers.put("Referer", rawUrl);
        headers.put("Origin", ORIGIN);
        headers.put("Accept", "text/html,application/xhtml+xml");
        headers.put("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
        Request request = request(url.getPath(), "POST", cookie, headers,
            new byte[0], form.getBytes(StandardCharsets.UTF_8), new byte[0]);
        request.headers.remove("X-Requested-With");
        // Do not replay this mutating request on failure; retain the caller's recovery state.
        Response response = execute(request, true);
        if (!isSuccessfulDeletion(response, remoteId)) throw new IOException("Web deletion not confirmed");
    }

    static boolean isSuccessfulDeletion(Response response, String remoteId) {
        if (activityUrl(remoteId) == null || !isExpectedEndpoint(response.url, "/activities/" + remoteId)
            || response.body.length > MAX_RESPONSE_BYTES) return false;
        if (response.statusCode == 404) return true;
        if (response.statusCode == 401 || response.statusCode == 403
            || response.text().toLowerCase(Locale.ROOT).contains("log in")) return false;
        if (response.statusCode >= 300 && response.statusCode < 400) {
            if (response.location == null) return false;
            try {
                URI destination = response.url.resolve(response.location);
                return safeOrigin(destination) && "www.strava.com".equalsIgnoreCase(destination.getHost())
                    && ("/athlete/training".equals(destination.getRawPath()) || "/dashboard".equals(destination.getRawPath()));
            } catch (IllegalArgumentException ignored) { return false; }
        }
        return response.statusCode == 200 || response.statusCode == 204;
    }

    public Map<String, Object> upload(byte[] fit, String filename, String cookie) throws IOException {
        if (fit == null || fit.length == 0 || fit.length > MAX_FIT_BYTES || !isSafeUploadFilename(filename)) {
            throw new IOException("Invalid FIT upload");
        }
        String csrf = null;
        for (String path : new String[] {"/about", "/upload/select"}) {
            Response response = execute(request(
                path, "GET", cookie, Collections.singletonMap("Accept", "text/html"), null, null, null
            ));
            if (response.statusCode == 200) csrf = extractCSRFToken(response.text());
            if (csrf != null) break;
        }
        if (csrf == null) throw new IOException("Unable to verify web session");
        String boundary = "Boundary-" + UUID.randomUUID();
        String prefix = "--" + boundary + "\r\n"
            + "Content-Disposition: form-data; name=\"_method\"\r\n\r\npost\r\n"
            + "--" + boundary + "\r\n"
            + "Content-Disposition: form-data; name=\"authenticity_token\"\r\n\r\n" + csrf + "\r\n"
            + "--" + boundary + "\r\n"
            + "Content-Disposition: form-data; name=\"files[]\"; filename=\"" + filename + "\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n";
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("X-CSRF-Token", csrf);
        headers.put("Origin", ORIGIN);
        headers.put("Referer", ORIGIN + "/upload/select");
        headers.put("Content-Type", "multipart/form-data; boundary=" + boundary);
        Response response = execute(request(
            "/upload/files", "POST", cookie, headers,
            prefix.getBytes(StandardCharsets.UTF_8), fit,
            ("\r\n--" + boundary + "--\r\n").getBytes(StandardCharsets.UTF_8)
        ));
        return uploadResponse(response);
    }

    private Request request(
        String path, String method, String cookie, Map<String, String> extraHeaders,
        byte[] prefix, byte[] fit, byte[] suffix
    ) throws IOException {
        String normalized = normalizeCookieHeader(cookie);
        if (normalized == null) throw new IOException("Invalid web session");
        URI url = URI.create(ORIGIN + path);
        if (!isExpectedEndpoint(url, url.getPath())) throw new IOException("Invalid request endpoint");
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Cookie", normalized);
        headers.put("X-Requested-With", "XMLHttpRequest");
        headers.put("Referer", ORIGIN + "/athlete/training");
        headers.putAll(extraHeaders);
        return new Request(url, method, headers, prefix, fit, suffix);
    }

    private Response execute(Request request) throws IOException { return execute(request, false); }

    private Response execute(Request request, boolean allowRedirectResponse) throws IOException {
        if (Thread.currentThread().isInterrupted()) throw new IOException("Web operation cancelled");
        Response response = transport.execute(request);
        if (!isExpectedEndpoint(response.url, request.url.getPath()) || response.body.length > MAX_RESPONSE_BYTES) {
            throw new IOException("Unexpected web response");
        }
        // Never accept a redirect as an authenticated probe, token page, or upload receipt.
        if (!allowRedirectResponse && response.statusCode >= 300 && response.statusCode < 400) {
            throw new IOException("Web session redirected");
        }
        return response;
    }

    public static boolean isAllowedLoginUrl(String raw) {
        try {
            URI url = new URI(raw);
            return safeOrigin(url) && LOGIN_HOSTS.contains(url.getHost().toLowerCase(Locale.ROOT));
        } catch (Exception ignored) { return false; }
    }

    private static boolean safeOrigin(URI url) {
        return url != null && "https".equalsIgnoreCase(url.getScheme()) && url.getHost() != null
            && url.getRawUserInfo() == null && (url.getPort() == -1 || url.getPort() == 443);
    }

    static boolean isExpectedEndpoint(URI url, String path) {
        return safeOrigin(url) && "www.strava.com".equalsIgnoreCase(url.getHost())
            && (REQUEST_PATHS.contains(path) || path.matches("/activities/[0-9]{1,32}(?:/streams)?"))
            && path.equals(url.getRawPath());
    }

    public static String activityUrl(String remoteId) {
        return remoteId != null && remoteId.matches("[0-9]{1,32}")
            ? ORIGIN + "/activities/" + remoteId : null;
    }

    public static boolean isSafeUploadFilename(String value) {
        return value != null && !value.isEmpty() && value.getBytes(StandardCharsets.UTF_8).length <= 128
            && value.toLowerCase(Locale.ROOT).endsWith(".fit") && !value.contains("..")
            && value.matches("[\\p{L}\\p{N}._-]+");
    }

    public static String normalizeCookieHeader(String raw) {
        if (raw == null) return null;
        String value = raw.trim();
        if (value.regionMatches(true, 0, "cookie:", 0, 7)) value = value.substring(7).trim();
        if (value.isEmpty() || value.getBytes(StandardCharsets.UTF_8).length > MAX_COOKIE_BYTES) return null;
        for (int i = 0; i < value.length(); i++) {
            if (value.charAt(i) < 0x20 || value.charAt(i) > 0x7e) return null;
        }
        for (String rawPair : value.split(";", -1)) {
            String pair = rawPair.trim();
            int equals = pair.indexOf('=');
            if (equals < 1 || !COOKIE_NAME.matcher(pair.substring(0, equals)).matches()) return null;
            String cookie = pair.substring(equals + 1);
            if (cookie.isEmpty()) return null;
            for (int i = 0; i < cookie.length(); i++) {
                char c = cookie.charAt(i);
                if (!(c == 0x21 || c >= 0x23 && c <= 0x2b || c >= 0x2d && c <= 0x3a
                    || c >= 0x3c && c <= 0x5b || c >= 0x5d && c <= 0x7e)) return null;
            }
        }
        return value;
    }

    public static String extractCSRFToken(String html) {
        Csrf pair = extractCSRFPair(html);
        return pair == null ? null : pair.token;
    }

    static Csrf extractCSRFPair(String html) {
        Matcher tags = TAG.matcher(html);
        String token = null;
        String parameter = "authenticity_token";
        while (tags.find()) {
            Map<String, String> attributes = new HashMap<>();
            Matcher attribute = ATTRIBUTE.matcher(tags.group());
            while (attribute.find()) attributes.put(attribute.group(1).toLowerCase(Locale.ROOT), attribute.group(3));
            String name = attributes.get("name");
            if ("csrf-param".equalsIgnoreCase(name) && attributes.containsKey("content")) parameter = attributes.get("content");
            String candidate = "csrf-token".equalsIgnoreCase(name) ? attributes.get("content")
                : "authenticity_token".equalsIgnoreCase(name) ? attributes.get("value") : null;
            if (token != null || candidate == null || candidate.isEmpty() || candidate.length() > 4096) continue;
            boolean valid = true;
            for (int i = 0; i < candidate.length(); i++) {
                if (candidate.charAt(i) < 0x21 || candidate.charAt(i) > 0x7e) { valid = false; break; }
            }
            if (valid) token = candidate;
        }
        if (token == null || !COOKIE_NAME.matcher(parameter).matches() || parameter.length() > 128
            || "_method".equals(parameter)) return null;
        return new Csrf(parameter, token);
    }

    static final class Csrf {
        final String parameter;
        final String token;
        Csrf(String parameter, String token) { this.parameter = parameter; this.token = token; }
    }

    static Map<String, Object> uploadResponse(Response response) throws IOException {
        int status = response.statusCode;
        boolean success = status >= 200 && status < 300;
        if (!isExpectedEndpoint(response.url, "/upload/files") || response.body.length > MAX_RESPONSE_BYTES
            || !(success || status == 400 || status == 409 || status == 422)) {
            throw new IOException("Web upload rejected");
        }
        String text = response.text();
        String duplicateId = null;
        if (text.toLowerCase(Locale.ROOT).contains("duplicate")) {
            Matcher matcher = DUPLICATE_ID.matcher(text);
            if (matcher.find()) duplicateId = matcher.group(1) == null ? matcher.group(2) : matcher.group(1);
        }
        boolean duplicate = duplicateId != null || DUPLICATE.matcher(text).find();
        if (!success && !duplicate) throw new IOException("Web upload rejected");
        Map<String, Object> payload = new HashMap<>();
        payload.put("isDuplicate", duplicate);
        if (duplicateId != null) payload.put("remoteId", duplicateId);
        return payload;
    }

    static byte[] readBounded(InputStream stream, long declaredLength) throws IOException {
        if (declaredLength > MAX_RESPONSE_BYTES) throw new IOException("Web response too large");
        if (stream == null) return new byte[0];
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int count;
        while ((count = stream.read(buffer)) != -1) {
            if (Thread.currentThread().isInterrupted()) throw new IOException("Web operation cancelled");
            if (output.size() + count > MAX_RESPONSE_BYTES) throw new IOException("Web response too large");
            output.write(buffer, 0, count);
        }
        return output.toByteArray();
    }

    interface Transport {
        Response execute(Request request) throws IOException;
        default void cancel() {}
    }

    static final class Request {
        final URI url;
        final String method;
        final Map<String, String> headers;
        final byte[] prefix;
        final byte[] fit;
        final byte[] suffix;
        Request(URI url, String method, Map<String, String> headers, byte[] prefix, byte[] fit, byte[] suffix) {
            this.url = url; this.method = method; this.headers = headers;
            this.prefix = prefix; this.fit = fit; this.suffix = suffix;
        }
    }

    public static final class Response {
        public final URI url;
        public final int statusCode;
        final byte[] body;
        final String location;
        Response(URI url, int statusCode, byte[] body) { this(url, statusCode, body, null); }
        Response(URI url, int statusCode, byte[] body, String location) {
            this.url = url; this.statusCode = statusCode; this.body = body; this.location = location;
        }
        public String text() { return new String(body, StandardCharsets.UTF_8); }
    }

    interface ConnectionFactory {
        HttpsURLConnection open(URI url) throws IOException;
    }

    static final class HttpsTransport implements Transport {
        private final ConnectionFactory connections;
        HttpsTransport() { this(url -> (HttpsURLConnection) url.toURL().openConnection()); }
        HttpsTransport(ConnectionFactory connections) { this.connections = connections; }
        private boolean cancelled;
        private HttpsURLConnection active;

        @Override public void cancel() {
            HttpsURLConnection connection;
            synchronized (this) { cancelled = true; connection = active; }
            if (connection != null) connection.disconnect();
        }

        @Override public Response execute(Request request) throws IOException {
            HttpsURLConnection connection;
            synchronized (this) {
                if (cancelled || Thread.currentThread().isInterrupted()) throw new IOException("Web operation cancelled");
                if (!isExpectedEndpoint(request.url, request.url.getPath())) throw new IOException("Invalid request endpoint");
                connection = connections.open(request.url);
                active = connection;
            }
            try {
                connection.setInstanceFollowRedirects(false);
                connection.setConnectTimeout(30_000);
                connection.setReadTimeout(30_000);
                connection.setUseCaches(false);
                connection.setRequestMethod(request.method);
                for (Map.Entry<String, String> header : request.headers.entrySet()) {
                    connection.setRequestProperty(header.getKey(), header.getValue());
                }
                if (request.fit != null) {
                    connection.setDoOutput(true);
                    connection.setFixedLengthStreamingMode((long) request.prefix.length + request.fit.length + request.suffix.length);
                    try (OutputStream output = connection.getOutputStream()) {
                        output.write(request.prefix);
                        for (int offset = 0; offset < request.fit.length; offset += 8192) {
                            if (Thread.currentThread().isInterrupted()) throw new IOException("Web operation cancelled");
                            output.write(request.fit, offset, Math.min(8192, request.fit.length - offset));
                        }
                        output.write(request.suffix);
                    }
                }
                int status = connection.getResponseCode();
                URI responseUrl = URI.create(connection.getURL().toString());
                if (!isExpectedEndpoint(responseUrl, request.url.getPath())) throw new IOException("Unexpected response endpoint");
                try (InputStream input = status >= 400 ? connection.getErrorStream() : connection.getInputStream()) {
                    return new Response(responseUrl, status, readBounded(input, connection.getContentLengthLong()), connection.getHeaderField("Location"));
                }
            } finally {
                synchronized (this) { if (active == connection) active = null; }
                connection.disconnect();
            }
        }
    }
}
