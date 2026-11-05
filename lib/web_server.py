#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""浏览器用的 GitHub 加速服务。

浏览器访问 http://127.0.0.1:<端口>/gh/<原始地址路径>，
这里把请求转给加速节点，再把结果送回浏览器。

节点各有各的本事：有的能代理网页但不管样式文件，
有的能代理样式文件但网页只给一张自己的首页。
这个服务按请求类型分给不同节点，哪边抽风了就换那边。

走普通 HTTP，不装证书、不改系统设置，关掉就恢复原样。
只面向 macOS / Linux。
"""

import argparse
import http.server
import os
import random
import re
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.request

# 浏览器打开一个页面会同时发几十个请求。直接一股脑丢给节点，
# 节点会限流，一半资源就取不回来了。
# 这里自己排队，一次只放少量请求过去。
FETCH_SLOTS = 8
_fetch_slots = threading.Semaphore(FETCH_SLOTS)

# 页面里的样式、脚本，文件名里都带内容哈希，内容不会变。
# 取过一次就存下来，下次直接用，既快又不占节点。
CACHE_DIR = os.path.join(os.path.expanduser("~"), ".hermes-cn", "web", "cache")
CACHE_MAX = 256 * 1024 * 1024


def set_cache_dir(path):
    global CACHE_DIR
    if path:
        CACHE_DIR = os.path.join(path, "cache")


def _cache_path(target):
    """按地址算一个缓存文件名。"""
    import hashlib

    key = hashlib.sha256(target.encode("utf-8")).hexdigest()[:32]
    return os.path.join(CACHE_DIR, key)


def _cache_read(path):
    try:
        with open(path, "rb") as fh:
            # 先读头部那一行，再按头部写的长度读正文。
            # 一次读固定字节数会把正文截断，那样缓存就永远读不中了。
            line = fh.readline()
            if not line.startswith(b"CNWC1|"):
                return None
            meta = line[:-1].decode("utf-8", "replace")
            parts = meta.split("|")
            if len(parts) != 4:
                return None
            ctype = parts[1]
            code = int(parts[2])
            length = int(parts[3])
            data = fh.read(length)
            if len(data) != length:
                return None
            return code, ctype, data
    except Exception:
        return None


def _cache_write(path, code, ctype, body):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = path + ".tmp%d" % os.getpid()
        with open(tmp, "wb") as fh:
            fh.write(b"CNWC1|")
            fh.write(ctype.encode("utf-8"))
            fh.write(b"|")
            fh.write(str(code).encode("utf-8"))
            fh.write(b"|")
            fh.write(str(len(body)).encode("utf-8"))
            fh.write(b"\n")
            fh.write(body)
        os.replace(tmp, path)
    except Exception:
        pass


def _cache_prune():
    """缓存别无限涨。"""
    try:
        files = []
        total = 0
        for name in os.listdir(CACHE_DIR):
            p = os.path.join(CACHE_DIR, name)
            try:
                st = os.stat(p)
            except OSError:
                continue
            files.append((st.st_mtime, st.st_size, p))
            total += st.st_size
        if total <= CACHE_MAX:
            return
        files.sort()
        for _mtime, size, p in files:
            try:
                os.remove(p)
                total -= size
            except OSError:
                pass
            if total <= CACHE_MAX * 0.7:
                break
    except Exception:
        pass


def _is_page(rest):
    """这个请求要的是网页本身，还是页面上的资源。

    网页不缓存：仓库内容会变，缓存了就看到旧的了。
    资源可以缓存：样式、脚本、图片的文件名里带内容哈希，内容不会变。
    """
    host = rest.split("/", 1)[0].lower()
    if host in ("github.com", "www.github.com", "gist.github.com"):
        return True
    # 资源域名下带 /assets/ 的也是资源
    return False

# 页面里指向 GitHub 的绝对链接，改成走本地服务
ASSET_DOMAINS = (
    "github.githubassets.com",
    "avatars.githubusercontent.com",
    "user-images.githubusercontent.com",
)

# 页面里出现、并且要跟着一起加速的域名。
# api.github.com 也要管：页面里的脚本会调它，
# 漏了就变成直连，等于那部分请求没走加速。
GITHUB_DOMAINS = (
    "github.com",
    "api.github.com",
) + ASSET_DOMAINS


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    # 由主进程注入：网页节点、样式文件节点、端口
    # 每个节点是 (前缀, 形态)
    web_nodes = ()
    asset_nodes = ()
    port = 0

    # 每个请求自己一个连接，不复用。
    # 浏览器会同时发很多请求，复用连接的话这里容易卡住。
    protocol_version = "HTTP/1.0"
    server_version = "hermes-cn-web"

    def log_message(self, fmt, *args):
        # 默认不往终端刷日志，安静些
        pass

    def log_error(self, fmt, *args):
        # 错误也记下来，但别刷屏
        try:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))
            sys.stderr.flush()
        except Exception:
            pass

    def _pick_prefix(self, host):
        """按域名决定用哪个节点。"""
        host = (host or "").lower()
        if host in ("github.com", "www.github.com"):
            return self.web_prefix or self.asset_prefix
        return self.asset_prefix or self.web_prefix

    def _candidates(self, host):
        """这次请求可以试的节点，按顺序来。

        每个节点是 (前缀, 形态)：
          prefix —— 前缀形态，原始地址整段接在后面
          site   —— 整站形态，地址里要去掉 github.com/ 这一段
        """
        host = (host or "").lower()
        if host in ("github.com", "www.github.com"):
            ordered = list(self.web_nodes)
        else:
            # 接口、样式、图片这些都走资源节点。
            # 实测网页节点不支持 api.github.com（返回 403 或 404），
            # 资源节点才代理得了。
            ordered = list(self.asset_nodes)
        seen = set()
        out = []
        for item in ordered:
            prefix = (item[0] or "").strip()
            mode = (item[1] or "prefix").strip()
            if not prefix:
                continue
            key = prefix + "|" + mode
            if key in seen:
                continue
            seen.add(key)
            out.append((prefix, mode))
        return out

    def _build_target(self, prefix, mode, rest, query):
        """拼出真正要取的地址。"""
        if mode == "site":
            # 整站形态：去掉 github.com/ 这段
            if rest.startswith("github.com/"):
                rest = rest[len("github.com/"):]
            elif rest == "github.com":
                rest = ""
            target = prefix + rest
        else:
            target = prefix + rest
        if query:
            target += "?" + query
        return target

    def _rewrite_html(self, body):
        """把页面里的绝对链接改成走本地服务。"""
        try:
            text = body.decode("utf-8", errors="replace")
        except Exception:
            return body
        base = "http://127.0.0.1:%d/gh" % self.port
        for domain in GITHUB_DOMAINS:
            text = text.replace("https://" + domain + "/", base + "/" + domain + "/")
            text = text.replace("https://" + domain + "\"", base + "/" + domain + "\"")
            # 协议相对地址（//github.com/...）同样要改
            text = text.replace("//" + domain + "/", base + "/" + domain + "/")
            text = text.replace("//" + domain + "\"", base + "/" + domain + "\"")
        return text.encode("utf-8")

    def _fetch(self, target, timeout=30):
        """取回内容。

        这里刻意不装成浏览器。有些节点会反过来拦浏览器的 UA，
        对普通命令行工具的请求反而放行。

        排队等空位，避免把节点打爆。
        """
        req = urllib.request.Request(
            target,
            headers={
                "User-Agent": "curl/8.7.1",
                "Accept": "*/*",
            },
        )
        acquired = _fetch_slots.acquire(timeout=60)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.getcode(), resp.headers.get("Content-Type", "application/octet-stream"), resp.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.headers.get("Content-Type", "text/plain"), exc.read()
        except Exception as exc:
            return 502, "text/plain", ("转发失败：%s" % exc).encode("utf-8")
        finally:
            if acquired:
                try:
                    _fetch_slots.release()
                except Exception:
                    pass

    def _handle(self):
        # 浏览器可能带着请求体来（POST）。不读掉的话连接状态会错乱，
        # 后面同一个连接上的请求就读不到了。
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            length = 0
        if length > 0:
            try:
                self.rfile.read(length)
            except Exception:
                pass

        raw_path = self.path
        query = ""
        if "?" in raw_path:
            raw_path, query = raw_path.split("?", 1)

        if raw_path.startswith("/gh/"):
            # 完整写法：/gh/github.com/owner/repo
            rest = raw_path[4:]
        else:
            # 相对链接写法：/owner/repo/issues
            # GitHub 的页面里大量用这种根路径相对链接，
            # 浏览器会按当前域名解析。不接管的话点一下就 404。
            rest = "github.com" + raw_path

        if not rest or rest == "github.com":
            rest = "github.com/"

        host = rest.split("/", 1)[0]
        candidates = self._candidates(host)

        # 缓存命中就直接给，不用问节点
        cached = None
        cacheable = True
        if candidates:
            prefix, mode = candidates[0]
            cache_key = self._build_target(prefix, mode, rest, query)
            # 页面本身不缓存：仓库内容会变，缓存了就看到旧的了。
            # 样式、脚本、图片这些文件名带哈希，内容不会变，可以放心存。
            if not _is_page(rest):
                cached = _cache_read(_cache_path(cache_key))
        if cached:
            code, ctype, body = cached
        else:
            code, ctype, body = 502, "text/plain", b""

            for prefix, mode in candidates:
                target = self._build_target(prefix, mode, rest, query)
                code, ctype, body = self._fetch(target)
                # 节点抽风或者限流时会返回 502 或者空内容，换下一个节点再试
                if code == 200 and body:
                    break
                # 偶尔会被限流，隔一下重试同一个节点
                if code in (429, 502, 503, 504):
                    time.sleep(0.8)
                    code, ctype, body = self._fetch(target)
                    if code == 200 and body:
                        break

            if code == 200 and body and cacheable:
                # 存起来，下次直接用
                try:
                    prefix, mode = candidates[0]
                    cache_key = self._build_target(prefix, mode, rest, query)
                    _cache_write(_cache_path(cache_key), code, ctype, body)
                except Exception:
                    pass

        # 偶尔清一下旧缓存
        if random.random() < 0.02:
            threading.Thread(target=_cache_prune, daemon=True).start()

        if code != 200:
            page = (
                "<!DOCTYPE html><html><head><meta charset='utf-8'>"
                "<title>加速节点暂时不可用</title></head><body>"
                "<h1>加速节点暂时不可用</h1>"
                "<p>所有备选节点都没能取回这个页面。稍等一会儿再试，或者重新启动服务：</p>"
                "<pre>hermes-cn.sh web serve</pre>"
                "<p>你也可以直接用浏览器打开官方地址：</p>"
                "<p><a href='https://github.com/'>https://github.com/</a></p>"
                "</body></html>"
            )
            body = page.encode("utf-8")
            ctype = "text/html; charset=utf-8"

        if "text/html" in (ctype or "").lower():
            body = self._rewrite_html(body)

        try:
            self.send_response(code)
            self.send_header("Content-Type", ctype or "application/octet-stream")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            self.log_error("写响应失败: %s", exc)

    do_GET = _handle
    do_HEAD = _handle
    do_POST = _handle


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    # 默认的等待队列只有 5，浏览器一开页面就是几十个请求，
    # 超出部分会被系统直接丢掉。这里调大一些。
    request_queue_size = 128


def read_args(path):
    """从配置文件读参数。

    每行一个：「关键字 值」。
    这样 bash 那边不用拼命令行，也就不用 bash 数组。

    网页节点和样式文件节点的格式是「前缀|形态」，
    形态有 prefix（前缀）和 site（整站）两种。
    """
    conf = {
        "port": 0,
        "web": [],
        "asset": [],
        "cachedir": "",
    }
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line.strip():
                    continue
                parts = line.split(" ", 1)
                key = parts[0].strip()
                val = parts[1].strip() if len(parts) > 1 else ""
                if key == "port":
                    try:
                        conf["port"] = int(val)
                    except ValueError:
                        pass
                elif key in ("web", "asset"):
                    bits = val.split("|")
                    prefix = bits[0].strip()
                    mode = bits[1].strip() if len(bits) > 1 else "prefix"
                    if prefix:
                        conf[key].append((prefix, mode))
                elif key == "cachedir":
                    conf["cachedir"] = val
    except OSError as exc:
        sys.stderr.write("读不到参数文件：%s\n" % exc)
        raise
    return conf


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--args", required=True)
    args = parser.parse_args()

    conf = read_args(args.args)

    if conf.get("cachedir"):
        set_cache_dir(conf["cachedir"])

    ProxyHandler.web_nodes = tuple(conf["web"])
    ProxyHandler.asset_nodes = tuple(conf["asset"])
    ProxyHandler.port = conf["port"]

    server = Server(("127.0.0.1", conf["port"]), ProxyHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
