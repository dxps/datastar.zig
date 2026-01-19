== File handler with variable mime type ==

r.get("/examples/assets/mime-tests/:filename");

fn mimeTest(http: *HTTPRequest) !void {
    return http.sendFile(http.path, null);
}
