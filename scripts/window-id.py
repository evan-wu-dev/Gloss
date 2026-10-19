#!/usr/bin/env python3
"""打印某个进程最上面那个窗口的 CGWindowID，给 screencapture -l 用：window-id.py <pid> [最小宽度]"""
import sys
import Quartz

pid = int(sys.argv[1])
min_width = float(sys.argv[2]) if len(sys.argv) > 2 else 40
windows = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID)
for w in windows:
    bounds = w.get("kCGWindowBounds", {})
    if w.get("kCGWindowOwnerPID") == pid and bounds.get("Width", 0) >= min_width and w.get("kCGWindowLayer", 0) >= 0:
        print(w["kCGWindowNumber"], int(bounds["X"]), int(bounds["Y"]), int(bounds["Width"]), int(bounds["Height"]), w.get("kCGWindowLayer"))
