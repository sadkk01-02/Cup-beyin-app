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
      title: 'CUP Harici Beyin',
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
  final Guid serviceUuid = Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914b");
  final Guid statusUuid  = Guid("beb5483e-36e1-4688-b7f5-ea07361b26a8");
  final Guid configUuid  = Guid("1c95d5e3-d8f7-413a-bf3d-7a2e5d7be87e");

  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? configChar;

  int rpm = 0;
  bool launchActive = false;
  bool cutActive = false;
  bool isScanning = false;
  String activeModeLabel = "HAZIR";

  double normRpm = 9500;
  double launchRpm = 5500;
  double cutMs = 40;

  Future<void> scanAndConnect() async {
    if (isScanning) return;
    setState(() => isScanning = true);

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));

    final sub = FlutterBluePlus.scanResults.listen((results) async {
      for (final ScanResult r in results) {
        if (r.device.platformName == "CUP-BEYIN-BLE" && connectedDevice == null) {
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
                  configChar = null;
                  rpm = 0;
                  launchActive = false;
                  cutActive = false;
                });
              }
            });
            await discoverServices(r.device);
          } catch (_) {
            if (mounted) setState(() => isScanning = false);
          }
          break;
        }
      }
    });

    await Future.delayed(const Duration(seconds: 6));
    await sub.cancel();
    if (mounted && isScanning) {
      setState(() => isScanning = false);
    }
  }

  Future<void> discoverServices(BluetoothDevice device) async {
    final List<BluetoothService> services = await device.discoverServices();
    for (final BluetoothService s in services) {
      if (s.uuid == serviceUuid) {
        for (final BluetoothCharacteristic c in s.characteristics) {
          if (c.uuid == statusUuid) {
            await c.setNotifyValue(true);
            c.onValueReceived.listen((value) {
              final String raw = utf8.decode(value, allowMalformed: true).trim();
              final List<String> parts = raw.split(',');
              if (parts.length == 3 && mounted) {
                setState(() {
                  rpm = int.tryParse(parts[0]) ?? 0;
                  launchActive = parts[1] == '1';
                  cutActive = parts[2] == '1';
                });
              }
            });
          } else if (c.uuid == configUuid) {
            configChar = c;
            final List<int> initVal = await c.read();
            final String raw = utf8.decode(initVal, allowMalformed: true).trim();
            final List<String> parts = raw.split(',');
            if (parts.length == 3 && mounted) {
              setState(() {
                normRpm = (double.tryParse(parts[0]) ?? 9500).clamp(3000, 14000);
                launchRpm = (double.tryParse(parts[1]) ?? 5500).clamp(2500, 10000);
                cutMs = (double.tryParse(parts[2]) ?? 40).clamp(15, 120);
              });
            }
          }
        }
      }
    }
  }

  Future<void> saveSettings({String? modeName}) async {
    if (modeName != null) {
      setState(() => activeModeLabel = modeName);
    }
    if (configChar == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Önce CG-BEYIN-BLE cihazına bağlan.")),
        );
      }
      return;
    }

    final String payload = "${normRpm.round()},${launchRpm.round()},${cutMs.round()}";
    await configChar!.write(utf8.encode(payload));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Kaydedildi: $payload")),
      );
    }
  }

  void applyPreset(String label, double n, double l, double m) {
    setState(() {
      normRpm = n;
      launchRpm = l;
      cutMs = m;
      activeModeLabel = label;
    });
    saveSettings(modeName: label);
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
            // --- DEVİR VE DURUM PANELİ ---
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

            // --- HAZIR MOD BUTONLARI ---
            Row(
              children: [
                Expanded(
                  child: _ModeButton(
                    title: "GÜNLÜK",
                    subtitle: "9500 • 35ms",
                    color: const Color(0xFF263238),
                    onTap: () => applyPreset("GÜNLÜK", 9500, 5500, 35),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ModeButton(
                    title: "POPCORN",
                    subtitle: "8500 • 25ms",
                    color: const Color(0xFFE65100),
                    onTap: () => applyPreset("POPCORN", 8500, 5000, 25),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ModeButton(
                    title: "ALEV / CUT",
                    subtitle: "8000 • 75ms",
                    color: const Color(0xFFB71C1C),
                    onTap: () => applyPreset("ALEV / CUT", 8000, 4800, 75),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 14),

            // --- KAYDIRMALI AYARLAR ---
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
                style: const TextStyle(fontSize: 10, color: Colors.white75),
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
