// Cleaner.cs - background watchers for Dev Control's cleaner (compiled by Core.ps1 with Add-Type).
// Keep this file ASCII-only and C# 5 (the .NET Framework csc that Add-Type uses).
//
// Watch.Start(dataDir, chromePort) runs two threads in the Dev Control process:
//  - TCP: every 30 s, which listening sockets had a connection, and from which local process
//    (cleaner-net.json). No process is started for this (GetExtendedTcpTable).
//  - Tabs: a DevTools connection to the automation Chrome (Target.setDiscoverTargets, browser
//    level, never attached to a page) that follows every tab's URL and who changed it
//    (cleaner-tabs.json). A URL change while a DevTools client is attached to the tab (or within
//    30 s after one detached) is automation's; a change with no client attached is the user's,
//    and the tab is the user's from then on.
// Invoke-DcCleanup (Core.ps1) reads both files and decides what to stop or close.
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace DevControl.Cleaner {

  public class TcpRow {
    public int State; public int LocalPort; public int RemotePort; public int Pid; public bool RemoteLoopback;
  }

  public static class Net {
    [DllImport("iphlpapi.dll")]
    static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int af, int tableClass, uint reserved);
    const int AF_INET = 2, AF_INET6 = 23, TCP_TABLE_OWNER_PID_ALL = 5;
    public const int LISTEN = 2, ESTABLISHED = 5;

    static int Port(int raw) { return ((raw & 0xFF) << 8) | ((raw >> 8) & 0xFF); }

    public static List<TcpRow> Rows() {
      var rows = new List<TcpRow>();
      Read(AF_INET, rows);
      Read(AF_INET6, rows);
      return rows;
    }

    static void Read(int af, List<TcpRow> rows) {
      int size = 0;
      GetExtendedTcpTable(IntPtr.Zero, ref size, false, af, TCP_TABLE_OWNER_PID_ALL, 0);
      for (int attempt = 0; attempt < 3; attempt++) {
        size += 4096;
        IntPtr buf = Marshal.AllocHGlobal(size);
        try {
          uint rc = GetExtendedTcpTable(buf, ref size, false, af, TCP_TABLE_OWNER_PID_ALL, 0);
          if (rc == 122) continue;   // ERROR_INSUFFICIENT_BUFFER: the table grew, try again
          if (rc != 0) return;
          int n = Marshal.ReadInt32(buf);
          for (int i = 0; i < n; i++) {
            var r = new TcpRow();
            if (af == AF_INET) {
              IntPtr e = new IntPtr(buf.ToInt64() + 4 + i * 24);
              r.State = Marshal.ReadInt32(e, 0);
              r.LocalPort = Port(Marshal.ReadInt32(e, 8));
              r.RemoteLoopback = Marshal.ReadByte(e, 12) == 127;
              r.RemotePort = Port(Marshal.ReadInt32(e, 16));
              r.Pid = Marshal.ReadInt32(e, 20);
            } else {
              IntPtr e = new IntPtr(buf.ToInt64() + 4 + i * 56);
              r.LocalPort = Port(Marshal.ReadInt32(e, 20));
              byte[] ra = new byte[16]; Marshal.Copy(new IntPtr(e.ToInt64() + 24), ra, 0, 16);
              bool v6loop = true; for (int k = 0; k < 15; k++) if (ra[k] != 0) v6loop = false;
              v6loop = v6loop && ra[15] == 1;
              bool mapped = ra[10] == 0xFF && ra[11] == 0xFF && ra[12] == 127;
              r.RemoteLoopback = v6loop || mapped;
              r.RemotePort = Port(Marshal.ReadInt32(e, 44));
              r.State = Marshal.ReadInt32(e, 48);
              r.Pid = Marshal.ReadInt32(e, 52);
            }
            rows.Add(r);
          }
          return;
        } finally { Marshal.FreeHGlobal(buf); }
      }
    }
  }

  public static class Mem {
    [StructLayout(LayoutKind.Sequential)]
    struct PerfInfo {
      public int cb;
      public UIntPtr CommitTotal, CommitLimit, CommitPeak, PhysicalTotal, PhysicalAvailable, SystemCache,
                     KernelTotal, KernelPaged, KernelNonpaged, PageSize;
      public int HandleCount, ProcessCount, ThreadCount;
    }
    [DllImport("psapi.dll", SetLastError = true)]
    static extern bool GetPerformanceInfo(out PerfInfo pi, int cb);

    // Paged + nonpaged kernel pool, in bytes (-1 if unreadable).
    public static long KernelPoolBytes() {
      PerfInfo pi;
      if (!GetPerformanceInfo(out pi, Marshal.SizeOf(typeof(PerfInfo)))) return -1;
      return ((long)pi.KernelPaged.ToUInt64() + (long)pi.KernelNonpaged.ToUInt64()) * (long)pi.PageSize.ToUInt64();
    }
  }

  public static class Watch {
    static Thread tcpThread, tabThread;
    static volatile bool stopping;
    static string dir;
    static int chromePort;
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024 };
    public static string LastError = "";
    public static string TabStatus = "not started";

    public static bool Running { get { return tcpThread != null && tcpThread.IsAlive; } }

    public static void Start(string dataDir, int port) {
      if (Running) return;
      dir = dataDir; chromePort = port; stopping = false;
      tcpThread = new Thread(TcpLoop); tcpThread.IsBackground = true; tcpThread.Name = "DevControl.Cleaner.Tcp"; tcpThread.Start();
      tabThread = new Thread(TabLoop); tabThread.IsBackground = true; tabThread.Name = "DevControl.Cleaner.Tabs"; tabThread.Start();
    }

    public static void Stop() { stopping = true; }

    static string Now() { return DateTime.UtcNow.ToString("o"); }

    static void Sleep(int ms) { for (int t = 0; t < ms && !stopping; t += 250) Thread.Sleep(250); }

    static void Save(string name, object value) {
      string path = Path.Combine(dir, name), tmp = path + ".tmp";
      File.WriteAllText(tmp, Json.Serialize(value), Encoding.UTF8);
      if (File.Exists(path)) File.Replace(tmp, path, null); else File.Move(tmp, path);
    }

    static Dictionary<string, object> Load(string name) {
      try {
        string path = Path.Combine(dir, name);
        if (!File.Exists(path)) return null;
        return Json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
      } catch { return null; }
    }

    static Dictionary<string, object> Obj(object o) { return o as Dictionary<string, object> ?? new Dictionary<string, object>(); }

    // ------------------------------------------------------------------ TCP activity
    // servers["pid:port"] = { firstSeen, lastActive (null until a connection is seen), clients { pid: { name, lastSeen } } }

    static void TcpLoop() {
      var servers = new Dictionary<string, object>();
      var old = Load("cleaner-net.json");
      if (old != null && old.ContainsKey("servers")) servers = Obj(old["servers"]);
      var names = new Dictionary<int, string>();
      DateTime lastSave = DateTime.MinValue;
      while (!stopping) {
        try {
          var rows = Net.Rows();
          var listening = new HashSet<string>();
          var byPair = new Dictionary<long, TcpRow>();   // established rows by (localPort, remotePort)
          foreach (var r in rows) {
            if (r.State == Net.LISTEN) listening.Add(r.Pid + ":" + r.LocalPort);
            else if (r.State == Net.ESTABLISHED) byPair[((long)r.LocalPort << 16) | (uint)r.RemotePort] = r;
          }
          string now = Now();
          foreach (string key in listening) if (!servers.ContainsKey(key)) {
            var s = new Dictionary<string, object>(); s["firstSeen"] = now; s["lastActive"] = null; s["clients"] = new Dictionary<string, object>();
            servers[key] = s;
          }
          foreach (var r in rows) {
            if (r.State != Net.ESTABLISHED) continue;
            string key = r.Pid + ":" + r.LocalPort;
            if (!listening.Contains(key)) continue;   // this end is a client, not an accepted connection
            var s = Obj(servers[key]);
            s["lastActive"] = now;
            TcpRow client;
            if (r.RemoteLoopback && byPair.TryGetValue(((long)r.RemotePort << 16) | (uint)r.LocalPort, out client)) {
              var clients = Obj(s.ContainsKey("clients") ? s["clients"] : null);
              string name;
              if (!names.TryGetValue(client.Pid, out name)) {
                try { name = System.Diagnostics.Process.GetProcessById(client.Pid).ProcessName; } catch { name = "?"; }
                names[client.Pid] = name;
              }
              var c = new Dictionary<string, object>(); c["name"] = name; c["lastSeen"] = now;
              clients[client.Pid.ToString()] = c;
              s["clients"] = clients;
            }
          }
          // forget listeners gone for a day
          var drop = new List<string>();
          foreach (var kv in servers) if (!listening.Contains(kv.Key)) {
            var s = Obj(kv.Value); object seen; DateTime t;
            string last = (s.TryGetValue("lastActive", out seen) && seen != null) ? (string)seen : (string)s["firstSeen"];
            if (DateTime.TryParse(last, null, System.Globalization.DateTimeStyles.RoundtripKind, out t) && (DateTime.UtcNow - t).TotalHours > 24) drop.Add(kv.Key);
          }
          foreach (string k in drop) servers.Remove(k);
          if (names.Count > 5000) names.Clear();
          if ((DateTime.UtcNow - lastSave).TotalSeconds >= 55) {
            var file = new Dictionary<string, object>(); file["updated"] = now; file["servers"] = servers;
            Save("cleaner-net.json", file); lastSave = DateTime.UtcNow;
          }
        } catch (Exception ex) { LastError = "tcp: " + ex.Message; }
        Sleep(30000);
      }
    }

    // ------------------------------------------------------------------ tabs of the automation Chrome
    // tabs[targetId] = { url, title, owner (auto | user | new | unknown), since (last URL change), firstSeen, attached, lastAttached }

    static Dictionary<string, object> tabs;
    static bool tabsDirty;

    static void TabLoop() {
      tabs = new Dictionary<string, object>();
      var old = Load("cleaner-tabs.json");
      if (old != null && old.ContainsKey("tabs")) tabs = Obj(old["tabs"]);
      while (!stopping) {
        string ws = BrowserSocketUrl();
        if (ws == null) { TabStatus = "no Chrome on port " + chromePort; Sleep(60000); continue; }
        try { Follow(ws); } catch (Exception ex) { LastError = "tabs: " + ex.Message; }
        TabStatus = "reconnecting";
        Sleep(15000);
      }
    }

    static string BrowserSocketUrl() {
      try {
        var req = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + chromePort + "/json/version");
        req.Proxy = null; req.Timeout = 3000; req.ReadWriteTimeout = 3000;
        using (var resp = req.GetResponse()) using (var sr = new StreamReader(resp.GetResponseStream())) {
          var v = Json.DeserializeObject(sr.ReadToEnd()) as Dictionary<string, object>;
          object u; if (v != null && v.TryGetValue("webSocketDebuggerUrl", out u)) return (string)u;
        }
      } catch { }
      return null;
    }

    static void Follow(string wsUrl) {
      using (var ws = new ClientWebSocket()) {
        ws.Options.Proxy = null;
        ws.ConnectAsync(new Uri(wsUrl), CancellationToken.None).Wait(10000);
        if (ws.State != WebSocketState.Open) throw new Exception("could not connect to " + wsUrl);
        TabStatus = "following Chrome on port " + chromePort;
        bool initial = true;   // until the reply to Target.getTargets (id 2): the authoritative list of open tabs
        Send(ws, "{\"id\":1,\"method\":\"Target.setDiscoverTargets\",\"params\":{\"discover\":true}}");
        Send(ws, "{\"id\":2,\"method\":\"Target.getTargets\"}");
        var buf = new byte[65536];
        var sb = new StringBuilder();
        DateTime lastSave = DateTime.MinValue;
        while (!stopping && ws.State == WebSocketState.Open) {
          var task = ws.ReceiveAsync(new ArraySegment<byte>(buf), CancellationToken.None);
          while (!task.Wait(2000)) {
            if (stopping) return;
            if (tabsDirty && (DateTime.UtcNow - lastSave).TotalSeconds >= 2) { SaveTabs(); lastSave = DateTime.UtcNow; }
          }
          var res = task.Result;
          if (res.MessageType == WebSocketMessageType.Close) break;
          sb.Append(Encoding.UTF8.GetString(buf, 0, res.Count));
          if (!res.EndOfMessage) continue;
          string msg = sb.ToString(); sb.Clear();
          var m = Json.DeserializeObject(msg) as Dictionary<string, object>;
          if (m == null) continue;
          object idv;
          if (m.TryGetValue("id", out idv)) {
            if (Convert.ToInt32(idv) != 2) continue;
            // Reconcile with what is open now: drop tabs closed while we were not connected; tabs we
            // never saw are 'unknown'; a known tab whose URL changed meanwhile goes through OnTarget
            // (unattached change = the user's).
            var open = new HashSet<string>();
            var result = Obj(m.ContainsKey("result") ? m["result"] : null);
            var list = result.ContainsKey("targetInfos") ? result["targetInfos"] as object[] : null;
            if (list == null) continue;
            foreach (object o in list) {
              var ti = Obj(o);
              if (!ti.ContainsKey("type") || (string)ti["type"] != "page") continue;
              string tid = (string)ti["targetId"];
              open.Add(tid);
              OnTarget(tid, ti, false, true);
            }
            var gone = new List<string>(); foreach (var k in tabs.Keys) if (!open.Contains(k)) gone.Add(k);
            foreach (var k in gone) tabs.Remove(k);
            initial = false;
            tabsDirty = true;
            continue;
          }
          object method; if (!m.TryGetValue("method", out method)) continue;
          var p = Obj(m.ContainsKey("params") ? m["params"] : null);
          string meth = (string)method;
          if (meth == "Target.targetDestroyed") {
            object tid; if (p.TryGetValue("targetId", out tid) && tabs.Remove((string)tid)) tabsDirty = true;
            continue;
          }
          if (meth != "Target.targetCreated" && meth != "Target.targetInfoChanged") continue;
          var info = Obj(p.ContainsKey("targetInfo") ? p["targetInfo"] : null);
          if (!info.ContainsKey("type") || (string)info["type"] != "page") continue;
          string id = (string)info["targetId"];
          OnTarget(id, info, meth == "Target.targetCreated", initial);
          if ((DateTime.UtcNow - lastSave).TotalSeconds >= 2) { SaveTabs(); lastSave = DateTime.UtcNow; }
        }
      }
    }

    static void Send(ClientWebSocket ws, string text) {
      var bytes = Encoding.UTF8.GetBytes(text);
      ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None).Wait(5000);
    }

    static bool BlankUrl(string u) {
      return u == "" || u == "about:blank" || u.StartsWith("chrome://newtab") || u.StartsWith("chrome://new-tab-page") || u.StartsWith("chrome-search://");
    }

    static void OnTarget(string id, Dictionary<string, object> info, bool created, bool initial) {
      string url = info.ContainsKey("url") ? (string)info["url"] : "";
      string title = info.ContainsKey("title") ? (string)info["title"] : "";
      bool attached = info.ContainsKey("attached") && info["attached"] is bool && (bool)info["attached"];
      string now = Now();
      object existing;
      Dictionary<string, object> t;
      if (!tabs.TryGetValue(id, out existing)) {
        t = new Dictionary<string, object>();
        t["firstSeen"] = now; t["since"] = now; t["url"] = url; t["lastAttached"] = null;
        string owner;
        if (initial) owner = "unknown";                    // open before we watched: history unknown
        else if (attached) owner = "auto";
        else {
          object opener; string from = null;
          if (info.TryGetValue("openerId", out opener) && opener != null && tabs.ContainsKey((string)opener))
            from = (string)Obj(tabs[(string)opener])["owner"];
          if (from != null) owner = from == "user" ? "user" : "auto";   // a popup belongs with its opener
          else if (BlankUrl(url)) owner = "new";           // Ctrl+T, or a page automation attaches to next
          else owner = "auto";                             // opened with a URL by a script (/json/new)
        }
        t["owner"] = owner;
        tabs[id] = t;
      } else {
        t = Obj(existing);
        string oldUrl = t.ContainsKey("url") ? (string)t["url"] : "";
        string owner = t.ContainsKey("owner") ? (string)t["owner"] : "unknown";
        bool recentAttach = false; object la; DateTime lt;
        if (t.TryGetValue("lastAttached", out la) && la != null &&
            DateTime.TryParse((string)la, null, System.Globalization.DateTimeStyles.RoundtripKind, out lt))
          recentAttach = (DateTime.UtcNow - lt).TotalSeconds <= 30;
        if (attached && owner == "new") owner = "auto";
        if (url != oldUrl) {
          if (owner != "user") owner = (attached || recentAttach) ? "auto" : (owner == "new" && BlankUrl(url) ? "new" : "user");
          t["url"] = url; t["since"] = now;
        }
        t["owner"] = owner;
      }
      if (attached) t["lastAttached"] = now;
      t["attached"] = attached;
      t["title"] = title;
      tabsDirty = true;
    }

    static void SaveTabs() {
      try {
        var file = new Dictionary<string, object>();
        file["updated"] = Now(); file["port"] = chromePort; file["tabs"] = tabs;
        Save("cleaner-tabs.json", file); tabsDirty = false;
      } catch (Exception ex) { LastError = "tabs save: " + ex.Message; }
    }
  }
}
