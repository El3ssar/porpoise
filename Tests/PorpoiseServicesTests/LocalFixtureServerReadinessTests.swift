import Foundation
import PorpoiseTestSupport
import Testing

struct LocalFixtureServerReadinessTests {
    @Test(arguments: ["", "pending"])
    func waitsForThePublishedPortBeforeConnecting(initial: String) async throws {
        let scratch = try Scratch()
        let script = try scratch.file(
            "delayed-port.py",
            """
            import argparse, http.server, pathlib, time
            parser = argparse.ArgumentParser()
            parser.add_argument('--port', type=int)
            parser.add_argument('--port-file')
            parser.add_argument('--initial')
            args = parser.parse_args()
            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'ready')
            server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
            port_file = pathlib.Path(args.port_file)
            port_file.write_text(args.initial)
            time.sleep(0.3)
            port_file.write_text(str(server.server_port))
            server.serve_forever()
            """)
        let server = try await offThePool { try LocalFixtureServer(script: script, arguments: ["--initial", initial]) }
        do {
            let (data, response) = try await URLSession.shared.data(from: server.base)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(data == Data("ready".utf8))
            await offThePool { server.stop() }
        } catch {
            await offThePool { server.stop() }
            throw error
        }
    }
}
