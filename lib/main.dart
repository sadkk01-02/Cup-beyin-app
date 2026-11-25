import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  runApp(const CupBeyinApp());
}

class CupBeyinApp extends StatelessWidget {
  const CupBeyinApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CG Harici Beyin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A0D),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF2A2A),
          secondary: Color(0xFFFF9100),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const String targetDeviceName = "CG-BEYİN-BLE";

  final Guid serviceUuid = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
  final Guid rxWriteUuid = Guid("6E400002-B5A3-F393-E0A9-E50E24DCCA9E"); // Uygulama -> ESP32
  final Guid txNotifyUuid = Guid("6E400003-B5A3-F393-E0A9-E50E24DCCA9E"); // ESP32 -> Uygulama

  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? writeChar;

  int rpm = 0;
  bool launchActive = false;
  bool cutActive = false;
  bool isScanning = false;
  String activeModeLabel = "HAZIR";

  double normRpm = 9500;
  double launchRpm = 4500;
  double cutMs = 35;

  bool _matchesTarget(ScanResult r) {
    final String pName = r.device.platformName.trim();
    final String aName = r.advertisementData.advName.trim();
    return pName == targetDeviceName ||
        aName == targetDeviceName ||
        pName.contains("BEYİN") ||
        aName.contains("BEYİN");
  }

  Future<void> scanAndConnect() async {
    if (isScanning) return;
    setState(() => isScanning = true);

    bool foundAndConnecting = false;

    final sub = FlutterBluePlus.scanResults.listen((results) async {
      if (foundAndConnecting || connectedDevice != null) return;
      for (final ScanResult r in results) {
        if (_matchesTarget(r)) {
          foundAndConnecting = true;
          await FlutterBluePlus.stopScan();
          try {
            await r.device.connect(autoConnect: false);
            if (!mounted) return;
            setState(() {
              connectedDevice = r.device;
              isScanning = false;
            });
            r.device.connectionState.listen((state) {
              if (state == BluetoothConnectionState.disconnected && mounted) {
                setState(() {
                  connectedDevice = null;
                  writeChar = null;
                  rpm = 0;
                  launchActive = false;
                  cutActive = false;
                });
              }
            });
            await discoverServices(r.device);
          } catch (_) {
            foundAndConnecting = false;
            if (mounted) setState(() => isScanning = false);
          }
          break;
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    await Future.delayed(const Duration(seconds: 8));
    await sub.cancel();

    if (mounted && isScanning) {
      setState(() => isScanning = false);
    }
  }

  void _parseTelemetry(String raw) {
    // Örnek format: RPM:0,LAUNCH:0,CUT:0,MODE:0,MAX:9500,L_RPM:4500
    final parts = raw.split(',');
    int? parsedRpm;
    bool? parsedLaunch;
    bool? parsedCut;
    int? parsedMode;
    double? parsedMax;
    double? parsedLaunchRpm;

    for (final item in parts) {
      final kv = item.split(':');
      if (kv.length != 2) continue;
      final key = kv[0].trim();
      final val = kv[1].trim();

      if (key == "RPM") {
        parsedRpm = int.tryParse(val);
      } else if (key == "LAUNCH") {
        parsedLaunch = val == "1";
      } else if (key == "CUT") {
        parsedCut = val == "1";
      } else if (key == "MODE") {
        parsedMode = int.tryParse(val);
      } else if (key == "MAX") {
        parsedMax = double.tryParse(val);
      } else if (key == "L_RPM") {
        parsedLaunchRpm = double.tryParse(val);
      }
    }

    if (!mounted) return;
    setState(() {
      if (parsedRpm != null) rpm = parsedRpm;
      if (parsedLaunch != null) launchActive = parsedLaunch;
      if (parsedCut != null) cutActive = parsedCut;
      if (parsedMode != null) {
        if (parsedMode == 0) activeModeLabel = "GÜNLÜK";
        if (parsedMode == 1) activeModeLabel = "POPCORN";
        if (parsedMode == 2) activeModeLabel = "ALEV / CUT";
      }
      if (parsedMax != null) normRpm = parsedMax.clamp(3000, 14000);
      if (parsedLaunchRpm != null) launchRpm = parsedLaunchRpm.clamp(2500, 10000);
    });
  }

  Future<void> discoverServices(BluetoothDevice device) async {
    final List<BluetoothService> services = await device.discoverServices();
    for (final BluetoothService s in services) {
      if (s.uuid == serviceUuid) {
        for (final BluetoothCharacteristic c in s.characteristics) {
          if (c.uuid == txNotifyUuid) {
            await c.setNotifyValue(true);
            c.onValueReceived.listen((value) {
              final String raw = utf8.decode(value, allowMalformed: true).trim();
              if (raw.isNotEmpty) {
                _parseTelemetry(raw);
              }
            });
          } else if (c.uuid == rxWriteUuid) {
            writeChar = c;
          }
        }
      }
    }
  }

  Future<void> _sendCmd(String cmd) async {
    if (writeChar == null) return;
    final bool withoutResp = writeChar!.properties.writeWithoutResponse;
    await writeChar!.write(utf8.encode(cmd), withoutResponse: withoutResp);
    await Future.delayed(const Duration(milliseconds: 60));
  }

  Future<void> saveSettings({String? modeName, int? modeCode}) async {
    if (modeName != null && mounted) {
      setState(() => activeModeLabel = modeName);
    }
    if (writeChar == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Önce CG-BEYİN-BLE cihazına bağlan.")),
        );
      }
      return;
    }

    if (modeCode != null) {
      await _sendCmd("MODE:$modeCode");
    }
    await _sendCmd("MAX:${normRpm.round()}");
    await _sendCmd("LAUNCH:${launchRpm.round()}");
    await _sendCmd("CUT_MS:${cutMs.round()}");

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Gönderildi: MAX ${normRpm.round()} | LAUNCH ${launchRpm.round()} | ${cutMs.round()}ms",
          ),
        ),
      );
    }
  }

  void applyPreset(String label, int modeCode, double n, double l, double m) {
    setState(() {
      normRpm = n;
      launchRpm = l;
      cutMs = m;
      activeModeLabel = label;
    });
    saveSettings(modeName: label, modeCode: modeCode);
  }

  Color _rpmColor(int current) {
    if (cutActive || current >= normRpm.round()) return const Color(0xFFFF1744);
    if (current >= (normRpm * 0.75).round()) return const Color(0xFFFF9100);
    return const Color(0xFF00E676);
  }

  @override
  Widget build(BuildContext context) {
    final bool isConnected = connectedDevice != null;
    final double maxScale = (normRpm + 2000).clamp(8000, 16000);
    final double rpmProgress = (rpm / maxScale).clamp(0.0, 1.0);
    final Color barColor = _rpmColor(rpm);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF131318),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "CG HARİCİ BEYİN",
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, letterSpacing: 1.1),
            ),
            Text(
              "MOD: $activeModeLabel",
              style: const TextStyle(fontSize: 11, color: Colors.white54, letterSpacing: 0.8),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton.icon(
              onPressed: isConnected ? null : scanAndConnect,
              style: FilledButton.styleFrom(
                backgroundColor: isConnected ? const Color(0xFF1B5E20) : const Color(0xFFFF2A2A),
                foregroundColor: Colors.white,
              ),
              icon: Icon(
                isConnected ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                size: 18,
              ),
              label: Text(
                isConnected ? "BAĞLI" : (isScanning ? "TARANIYOR" : "BAĞLAN"),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF14141A),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: cutActive ? const Color(0xFFFF1744) : Colors.white12,
                  width: cutActive ? 2 : 1,
                ),
              ),
              child: Column(
                children: [
                  const Text(
                    "ANLIK MOTOR DEVİRİ",
                    style: TextStyle(color: Colors.white54, fontSize: 12, letterSpacing: 1.6),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    "$rpm",
                    style: TextStyle(
                      fontSize: 54,
                      fontWeight: FontWeight.w900,
                      color: barColor,
                      height: 1.0,
                    ),
                  ),
                  const Text(
                    "RPM",
                    style: TextStyle(color: Colors.white38, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      value: rpmProgress,
                      minHeight: 16,
                      backgroundColor: Colors.black,
                      valueColor: AlwaysStoppedAnimation<Color>(barColor),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _StatusBox(
                          title: "LAUNCH",
                          active: launchActive,
                          activeColor: const Color(0xFFFF9100),
                          activeText: "AÇIK",
                          inactiveText: "KAPALI",
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StatusBox(
                          title: "KESİCİ",
                          active: cutActive,
                          activeColor: const Color(0xFFFF1744),
                          activeText: "PATLIYOR",
                          inactiveText: "PASİF",
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _ModeButton(
                    title: "GÜNLÜK",
                    subtitle: "9500 • 35ms",
                    color: const Color(0xFF263238),
                    onTap: () => applyPreset("GÜNLÜK", 0, 9500, 4500, 35),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ModeButton(
                    title: "POPCORN",
                    subtitle: "8500 • 25ms",
                    color: const Color(0xFFE65100),
                    onTap: () => applyPreset("POPCORN", 1, 8500, 4000, 25),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ModeButton(
                    title: "ALEV / CUT",
                    subtitle: "8000 • 75ms",
                    color: const Color(0xFFB71C1C),
                    onTap: () => applyPreset("ALEV / CUT", 2, 8000, 4800, 75),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _SliderTile(
              label: "Normal Kesici Devri",
              valueLabel: "${normRpm.round()} RPM",
              value: normRpm,
              min: 3000,
              max: 14000,
              divisions: 110,
              onChanged: (v) => setState(() {
                normRpm = v;
                activeModeLabel = "ÖZEL";
              }),
            ),
            _SliderTile(
              label: "Launch Devri",
              valueLabel: "${launchRpm.round()} RPM",
              value: launchRpm,
              min: 2500,
              max: 10000,
              divisions: 75,
              onChanged: (v) => setState(() {
                launchRpm = v;
                activeModeLabel = "ÖZEL";
              }),
            ),
            _SliderTile(
              label: "Kesici / Patlatma Hızı",
              valueLabel: "${cutMs.round()} ms",
              value: cutMs,
              min: 15,
              max: 120,
              divisions: 105,
              onChanged: (v) => setState(() {
                cutMs = v;
                activeModeLabel = "ÖZEL";
              }),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton.icon(
                onPressed: () => saveSettings(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF2A2A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.save_rounded),
                label: const Text(
                  "AYARLARI BEYNE KAYDET",
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 0.6),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBox extends StatelessWidget {
  final String title;
  final bool active;
  final Color activeColor;
  final String activeText;
  final String inactiveText;

  const _StatusBox({
    required this.title,
    required this.active,
    required this.activeColor,
    required this.activeText,
    required this.inactiveText,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: active ? activeColor.withOpacity(0.22) : const Color(0xFF0E0E12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: active ? activeColor : Colors.white12),
      ),
      child: Column(
        children: [
          Text(title, style: const TextStyle(fontSize: 11, color: Colors.white54, fontWeight: FontWeight.bold)),
          const SizedBox(height: 3),
          Text(
            active ? activeText : inactiveText,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: active ? activeColor : Colors.white60,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _ModeButton({
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          child: Column(
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Colors.white),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const _SliderTile({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: const Color(0xFF14141A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
              Text(valueLabel, style: const TextStyle(color: Color(0xFFFFD54F), fontSize: 15, fontWeight: FontWeight.bold)),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            activeColor: const Color(0xFFFF2A2A),
            inactiveColor: Colors.white12,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
