#!/usr/bin/env python3
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Cross-Origin-Embedder-Policy", "credentialless")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        super().end_headers()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", default="/private/tmp/doompeller-web-audio-harness")
    parser.add_argument("--port", type=int, default=8877)
    args = parser.parse_args()
    handler = partial(Handler, directory=args.directory)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    print(f"http://127.0.0.1:{args.port}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
