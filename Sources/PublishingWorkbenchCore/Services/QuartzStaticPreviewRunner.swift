import Foundation
import PublishingPreviewCore

/// Runs a Quartz 4 build in a disposable copy, then serves only its generated
/// files on loopback. Quartz's own `--serve` opens a second WebSocket listener
/// without a host-binding option, so the preview never invokes it.
enum QuartzStaticPreviewRunner {
  static let readyLogLine = "Quartz static preview ready on 127.0.0.1"

  static func arguments(
    rootPath: String,
    nodePath: String,
    port: Int,
    parentProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
  ) -> [String] {
    ["-I", "-c", pythonSource, rootPath, nodePath, String(port), String(parentProcessIdentifier)]
  }

  static func isValid(plan: LocalSitePreviewPlan) -> Bool {
    guard let port = plan.port,
      plan.siteKind == .quartz,
      plan.arguments.count == 7,
      plan.arguments[0] == "-I",
      plan.arguments[1] == "-c",
      plan.arguments[2] == pythonSource,
      plan.arguments[3] == plan.rootPath,
      plan.arguments[5] == String(port),
      plan.arguments[6] == String(ProcessInfo.processInfo.processIdentifier),
      LocalSitePreviewProcessService.isTrustedExecutable(atPath: plan.arguments[4])
    else { return false }
    return true
  }

  static func removeTemporaryDirectories(processIdentifier: Int32) {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let prefix = "RepoPress-Quartz-Preview-\(processIdentifier)-"
    guard
      let entries = try? manager.contentsOfDirectory(
        at: temporaryRoot,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
    else { return }
    for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
      guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
        values.isDirectory == true,
        values.isSymbolicLink != true,
        entry.deletingLastPathComponent().standardizedFileURL == temporaryRoot
      else { continue }
      do {
        try manager.removeItem(at: entry)
      } catch {
        // Stopping the preview must still complete. Record a local diagnostic
        // so a retained temporary snapshot is never silently ignored.
        NSLog(
          "RepoPress could not remove a Quartz preview temporary directory: %@",
          error.localizedDescription)
      }
    }
  }

  static let pythonSource = #"""
    import http.server
    import os
    from pathlib import Path
    import select
    import shutil
    import signal
    import stat
    import subprocess
    import sys
    import tempfile
    import time

    def contained(path, root):
        try:
            return os.path.commonpath((str(path), str(root))) == str(root)
        except ValueError:
            return False

    def reject_escaping_links(root):
        for directory, folders, files in os.walk(root, followlinks=False):
            if os.getppid() != parent_pid:
                raise RuntimeError("Quartz preview parent exited")
            for name in folders + files:
                path = Path(directory) / name
                if path.is_symlink() and not contained(path.resolve(strict=False), root):
                    raise RuntimeError("Quartz preview copy contains an escaping symbolic link")

    build = None

    def stop_build():
        global build
        if build is None:
            return
        # Node starts in its own session. Terminate the whole tree even if the
        # CLI launched a long-lived worker, then reap the direct child.
        try:
            os.killpg(build.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            build.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(build.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        build.wait()
        build = None

    def exit_on_signal(signum, frame):
        stop_build()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, exit_on_signal)
    signal.signal(signal.SIGINT, exit_on_signal)
    source = Path(sys.argv[1]).resolve(strict=True)
    node = Path(sys.argv[2]).resolve(strict=True)
    port = int(sys.argv[3])
    parent_pid = int(sys.argv[4])
    probe_token = os.environ.pop("REPOPRESS_QUARTZ_PREVIEW_TOKEN", "")
    if not source.is_dir() or not node.is_file() or not 0 < port < 65536 or not probe_token or os.getppid() != parent_pid:
        raise RuntimeError("Invalid Quartz preview inputs")

    with tempfile.TemporaryDirectory(prefix=f"RepoPress-Quartz-Preview-{os.getpid()}-") as temporary:
        workspace = Path(temporary).resolve()
        if contained(workspace, source):
            raise RuntimeError("Quartz preview temporary directory is inside the repository")
        staged = workspace / "source"
        public = workspace / "public"
        copy_deadline = time.monotonic() + \#(LocalSitePreviewStartupBudget.quartzCopyTimeoutSeconds)
        copied_bytes = 0
        copied_files = 0
        visited_directories = 0
        visited_entries = 0

        def check_copy_budget():
            if time.monotonic() >= copy_deadline:
                raise RuntimeError("Quartz preview copy exceeded its \#(LocalSitePreviewStartupBudget.quartzCopyTimeoutSeconds) second limit")
            if os.getppid() != parent_pid:
                raise RuntimeError("Quartz preview parent exited")

        def check_directory(directory, names):
            global visited_directories, visited_entries
            check_copy_budget()
            visited_directories += 1
            visited_entries += len(names)
            if visited_directories > 20000:
                raise RuntimeError("Quartz preview copy exceeded its directory limit")
            if visited_entries > 200000:
                raise RuntimeError("Quartz preview copy exceeded its entry limit")
            return []

        def bounded_copy(origin, destination):
            global copied_bytes, copied_files
            check_copy_budget()
            info = os.stat(origin, follow_symlinks=False)
            if not stat.S_ISREG(info.st_mode):
                raise RuntimeError("Quartz preview copy contains a non-regular file")
            copied_files += 1
            if copied_files > 200000 or copied_bytes + info.st_size > 2 * 1024**3:
                raise RuntimeError("Quartz preview copy exceeded its file or 2 GiB size limit")
            if shutil.disk_usage(workspace).free < info.st_size + 512 * 1024**2:
                raise RuntimeError("Quartz preview copy would exhaust available disk space")
            with open(origin, "rb") as input_file, open(destination, "wb") as output_file:
                while True:
                    check_copy_budget()
                    chunk = input_file.read(1024 * 1024)
                    if not chunk:
                        break
                    output_file.write(chunk)
                    copied_bytes += len(chunk)
            shutil.copystat(origin, destination, follow_symlinks=False)
            return destination

        shutil.copytree(source, staged, symlinks=True, ignore=check_directory, copy_function=bounded_copy)
        reject_escaping_links(staged)
        if not (staged / "quartz.config.ts").is_file() or not (staged / "quartz/bootstrap-cli.mjs").is_file():
            raise RuntimeError("Quartz 4 configuration or CLI is unavailable")
        environment = os.environ.copy()
        environment.update({"CI": "1", "HOME": str(workspace), "TMPDIR": str(workspace), "XDG_CACHE_HOME": str(workspace / "cache")})
        output_bytes = bytearray()
        output_stream = None
        try:
            build = subprocess.Popen(
                [str(node), "quartz/bootstrap-cli.mjs", "build", "--output", str(public)],
                cwd=staged, env=environment, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, start_new_session=True,
            )
            output_stream = build.stdout
            deadline = time.monotonic() + \#(LocalSitePreviewStartupBudget.quartzBuildTimeoutSeconds)
            while build.poll() is None:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Quartz preview build timed out")
                if os.getppid() != parent_pid:
                    raise RuntimeError("Quartz preview parent exited")
                if select.select([output_stream], [], [], 0.1)[0]:
                    chunk = os.read(output_stream.fileno(), 4096)
                    if not chunk:
                        time.sleep(0.1)
                        continue
                    output_bytes.extend(chunk)
                    if len(output_bytes) > 65536:
                        raise RuntimeError("Quartz preview build exceeded its log limit")
            build_status = build.returncode
        finally:
            stop_build()
            if output_stream is not None:
                os.set_blocking(output_stream.fileno(), False)
                while len(output_bytes) <= 65536:
                    try:
                        chunk = os.read(output_stream.fileno(), 4096)
                    except BlockingIOError:
                        break
                    if not chunk:
                        break
                    output_bytes.extend(chunk)
                output_stream.close()
            if output_bytes:
                print(output_bytes[:65536].decode("utf-8", errors="replace").replace(str(staged), str(source)), flush=True)
        if len(output_bytes) > 65536:
            raise RuntimeError("Quartz preview build exceeded its log limit")
        if build_status != 0 or public.is_symlink() or not (public / "index.html").is_file():
            raise RuntimeError("Quartz preview build failed or produced no index.html")
        reject_escaping_links(public)

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=str(public), **kwargs)

            def translate_path(self, request_path):
                candidate = Path(super().translate_path(request_path)).resolve(strict=False)
                return str(candidate if contained(candidate, public) else public / "__blocked__")

            def do_GET(self):
                if self.path == "/.__repopress_quartz_probe":
                    self.send_response(200)
                    self.send_header("X-RepoPress-Quartz-Preview", probe_token)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                super().do_GET()

            def list_directory(self, directory):
                self.send_error(403)
                return None

            def end_headers(self):
                self.send_header("Cache-Control", "no-store")
                super().end_headers()

            def log_message(self, format, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
        print("Quartz static preview ready on 127.0.0.1", flush=True)
        server.timeout = 1
        while os.getppid() == parent_pid:
            server.handle_request()
        server.server_close()
    """#
}
