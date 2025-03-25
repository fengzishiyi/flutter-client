import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';  // 提供 rootBundle 和 ByteData
import 'dart:typed_data';              // 提供 ByteData 类型

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    cameras = await availableCameras();
    runApp(const ColorAnalysisApp());
  } catch (e) {
    runApp(MaterialApp(home: ErrorScreen(error: '相机初始化失败: $e')));
  }
}

class ColorAnalysisApp extends StatelessWidget {
  const ColorAnalysisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '专业颜色分析仪',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const CameraScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  String? _error;
  AnalysisResult? _result;
  bool _isLoading = false;
  File? _targetImage;
  File? _backgroundImage;
  int _currentStep = 1; // 1:目标图, 2:背景图, 3:结果
  bool _isCameraReady = false;
  final _apiUrl = 'http://192.168.0.105:5000/analyze'; // 替换为你的实际API地址

  Future<void> _loadInitialImages() async {
    try {
      // 从assets加载图片
      final ByteData targetData = await rootBundle.load('assets/images/1.jpg');
      final ByteData bgData = await rootBundle.load('assets/images/1_bg.jpg');

      // 获取临时目录
      final Directory tempDir = await getTemporaryDirectory();

      // 保存为临时文件
      final File targetFile = File('${tempDir.path}/initial_target.jpg');
      final File bgFile = File('${tempDir.path}/initial_bg.jpg');

      await targetFile.writeAsBytes(targetData.buffer.asUint8List());
      await bgFile.writeAsBytes(bgData.buffer.asUint8List());

      if (mounted) {
        setState(() {
          _targetImage = targetFile;
          _backgroundImage = bgFile;
          _currentStep = 2; // 直接跳转到预览步骤
        });
      }
    } catch (e) {
      debugPrint('初始化图片加载失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('默认图片加载失败: ${e.toString()}')),
        );
      }
    }
  }


  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadInitialImages(); // 调用新方法
  }

  Future<bool> _checkServerConnection() async {
    try {
      print('正在测试服务器连接...');
      final response = await http.get(
        Uri.parse('http://10.0.2.2:5000/ping'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 3));

      print('服务器响应: ${response.statusCode} - ${response.body}');
      return response.statusCode == 200 && response.body.toLowerCase().contains('pong');
    } catch (e) {
      print('服务器连接测试失败: $e');
      return false;
    }
  }

  Future<void> _initializeCamera() async {
    try {
      if (cameras.isEmpty) throw Exception('没有可用的相机');

      _controller = CameraController(
        cameras[_currentStep == 1 ? 0 : 0], // 前后摄像头切换改为都使用后置摄像头
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _controller!.initialize();
      if (mounted) setState(() => _isCameraReady = true);
    } catch (e) {
      _handleError('相机初始化失败: ${e.toString()}');
    }
  }

  Future<void> _takePhoto() async {
    if (!_isCameraReady || _controller == null || !_controller!.value.isInitialized) {
      _handleError('相机未准备好');
      return;
    }

    setState(() => _isLoading = true);

    try {
      final image = await _controller!.takePicture();
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/${_currentStep == 1 ? 'target' : 'background'}_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await file.writeAsBytes(await image.readAsBytes());

      setState(() {
        if (_currentStep == 1) {
          _targetImage = file;
        } else {
          _backgroundImage = file;
        }
        _isLoading = false;

        // 只有拍完目标照片后才自动进入下一步
        if (_currentStep == 1) {
          _currentStep++;
          _initializeCamera(); // 重新初始化相机（可能需要切换摄像头）
        }
      });

    } catch (e) {
      _handleError('拍照失败: ${e.toString()}');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _testNetwork() async {
    try {
      final response = await http.get(Uri.parse('https://www.baidu.com')).timeout(Duration(seconds: 5));
      print('网络测试状态: ${response.statusCode}');
    } catch (e) {
      print('网络不可用: $e');
      _handleError('网络连接异常，请检查网络设置');
      throw Exception('网络不可用');
    }
  }

  Future<void> _analyzeImages() async {
    // 1. 前置检查
    if (_targetImage == null || !_targetImage!.existsSync()) {
      _handleError('目标样本图片无效，请重新拍摄');
      return;
    }

    if (_backgroundImage == null || !_backgroundImage!.existsSync()) {
      _handleError('背景参考图片无效，请重新拍摄');
      return;
    }

    // 2. 网络和服务检查
    setState(() => _isLoading = true);

    try {
      // 调试信息
      print('┌───────────────────────────');
      print('│ 开始分析流程');
      print('│ 目标图片: ${_targetImage!.path} (${_targetImage!.lengthSync()} bytes)');
      print('│ 背景图片: ${_backgroundImage!.path} (${_backgroundImage!.lengthSync()} bytes)');
      print('│ API地址: $_apiUrl');

      // 先检查服务器连通性
      print('├─ 检查服务器连接...');
      final pingResponse = await http.get(
        Uri.parse('$_apiUrl/ping'.replaceFirst('/analyze/ping', '/ping')),
      ).timeout(const Duration(seconds: 3));

      if (pingResponse.statusCode != 200) {
        throw Exception('服务器状态异常: ${pingResponse.statusCode}');
      }
      print('│ 服务器连接正常');

      // 3. 正式请求
      print('├─ 发送分析请求...');
      final stopwatch = Stopwatch()..start();

      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'target_image': base64Encode(await _targetImage!.readAsBytes()),
          'background_image': base64Encode(await _backgroundImage!.readAsBytes())
        }),
      ).timeout(const Duration(seconds: 15));

      stopwatch.stop();
      print('│ 请求完成 (耗时: ${stopwatch.elapsedMilliseconds}ms)');

      // 4. 处理响应
      if (response.statusCode == 200) {
        final jsonResponse = jsonDecode(response.body);

        if (jsonResponse['error'] != null) {
          throw Exception('服务器返回错误: ${jsonResponse['error']}');
        }

        print('│ 分析成功');
        print('└───────────────────────────');

        if (mounted) {
          setState(() {
            _result = AnalysisResult.fromJson(jsonResponse);
            _isLoading = false;
            _currentStep = 3; // 跳转到结果页
          });
        }
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } on TimeoutException {
      _handleError('请求超时，请检查网络状况');
      print('│ 请求超时');
      print('└───────────────────────────');
    } on SocketException catch (e) {
      _handleError('网络连接失败: ${e.message}');
      print('│ 网络连接异常: ${e.toString()}');
      print('└───────────────────────────');
    } catch (e) {
      _handleError('分析失败: ${e.toString().replaceAll('\n', ' ')}');
      print('│ 发生错误: ${e.toString()}');
      print('└───────────────────────────');
    } finally {
      if (mounted && _result == null) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _resetProcess() {
    setState(() {
      _currentStep = 1;
      _targetImage = null;
      _backgroundImage = null;
      _result = null;
    });
    _initializeCamera();
  }

  void _handleError(String message) {
    setState(() => _error = message);
    Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _error = null);
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('专业颜色分析'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            onPressed: _showHelpDialog,
          ),
        ],
      ),
      body: _buildContent(),
      floatingActionButton: _buildActionButton(),
      bottomNavigationBar: _error != null ? _buildErrorBar() : null,
    );
  }

  Widget _buildContent() {
    if (!_isCameraReady) return const Center(child: CircularProgressIndicator());

    return switch (_currentStep) {
      3 => _buildResultView(),
      2 => _buildPreviewView(),
      _ => _buildCameraView(),
    };
  }

  Widget _buildCameraView() => Column(
    children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: CameraPreview(_controller!),
          ),
        ),
      ),
      _buildStepIndicator(),
      const SizedBox(height: 16),
      Text(
        _currentStep == 1 ? '对准目标样本并拍照' : '对准背景参考并拍照',
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 24),
    ],
  );

  Widget _buildPreviewView() => Column(
    children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _buildImageCard('目标样本', _targetImage),
              const SizedBox(width: 16),
              _buildImageCard('背景参考', _backgroundImage),
            ],
          ),
        ),
      ),
      if (_backgroundImage == null) // 只有背景图片未拍摄时显示提示
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            '请拍摄背景参考照片',
            style: TextStyle(
              fontSize: 18,
              color: Colors.blue,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: ElevatedButton(
          onPressed: _backgroundImage != null ? _analyzeImages : null,
          style: ElevatedButton.styleFrom(
            minimumSize: const Size(double.infinity, 50),
            backgroundColor: _backgroundImage != null ? Colors.blue : Colors.grey,
          ),
          child: const Text('开始分析', style: TextStyle(fontSize: 18)),
        ),
      ),
      const SizedBox(height: 16),
    ],
  );

  Widget _buildResultView() => SingleChildScrollView(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (_result?.processedImage != null)
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  base64Decode(_result!.processedImage!.replaceFirst(
                    RegExp(r'data:image\/\w+;base64,'),
                    '',
                  )),
                  fit: BoxFit.contain,
                ),
              ),
            ),
          const SizedBox(height: 24),
          _buildResultCard(),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _resetProcess,
                  child: const Text('重新拍摄'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton(
                  onPressed: _saveResult,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                  ),
                  child: const Text('保存结果'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _buildImageCard(String title, File? image) => Expanded(
    child: Column(
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        Expanded(
          child: Card(
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: image != null
                  ? Image.file(image, fit: BoxFit.cover)
                  : const Center(child: Icon(Icons.photo, size: 50, color: Colors.grey)),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _buildResultCard() => Card(
    elevation: 4,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const Text('分析结果', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          _buildResultRow('预测浓度', '${_result?.concentration?.toStringAsFixed(2) ?? '--'} mg/L'),
          const Divider(),
          _buildResultRow('L通道值', _result?.colorInfo?.l?.toStringAsFixed(1) ?? '--'),
          _buildResultRow('a通道值', _result?.colorInfo?.a?.toStringAsFixed(1) ?? '--'),
          _buildResultRow('b通道值', _result?.colorInfo?.b?.toStringAsFixed(1) ?? '--'),
        ],
      ),
    ),
  );

  Widget _buildResultRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 16)),
        Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      ],
    ),
  );

  Widget _buildStepIndicator() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (index) {
            final isActive = _currentStep > index;
            return Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: isActive ? Colors.blue : Colors.grey[300],
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: isActive ? Colors.white : Colors.grey[700],
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                if (index < 2)
                  Container(
                    width: 30,
                    height: 2,
                    color: isActive ? Colors.blue : Colors.grey[300],
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                  ),
              ],
            );
          }),
        ),
        const SizedBox(height: 8),
        Text(
          _currentStep == 1
              ? '拍摄目标样本'
              : _currentStep == 2
              ? '拍摄背景参考'
              : '查看分析结果',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ],
    ),
  );

  Widget? _buildActionButton() {
    if (_currentStep == 3) return null; // 结果页面不需要拍照按钮

    return FloatingActionButton(
      onPressed: _isLoading ? null : _takePhoto,
      child: _isLoading
          ? const CircularProgressIndicator(color: Colors.white)
          : Icon(
        _currentStep == 1 ? Icons.camera_alt : Icons.camera,
        size: 32,
      ),
      backgroundColor: _isLoading ? Colors.grey : Colors.blue,
      tooltip: _currentStep == 1 ? '拍摄目标样本' : '拍摄背景参考',
    );
  }

  Widget _buildErrorBar() => Container(
    color: Colors.red,
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
    child: Row(
      children: [
        const Icon(Icons.error_outline, color: Colors.white),
        const SizedBox(width: 8),
        Expanded(child: Text(_error!, style: const TextStyle(color: Colors.white))),
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => setState(() => _error = null),
        ),
      ],
    ),
  );

  Future<void> _saveResult() async {
    // 实际项目中实现保存逻辑
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('结果已保存')),
    );
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('使用说明'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('1. 首先拍摄目标样本照片'),
              SizedBox(height: 8),
              Text('2. 然后拍摄背景参考照片'),
              SizedBox(height: 8),
              Text('3. 最后查看分析结果'),
              SizedBox(height: 16),
              Text('确保拍摄环境光线均匀，避免反光'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

class AnalysisResult {
  final double? concentration;
  final ColorInfo? colorInfo;
  final String? processedImage;

  AnalysisResult({this.concentration, this.colorInfo, this.processedImage});

  factory AnalysisResult.fromJson(Map<String, dynamic> json) {
    String? processedImage = json['processed_image'];
    if (processedImage != null) {
      processedImage = processedImage.replaceFirst(
          RegExp(r'data:image\/\w+;base64,'),
          ''
      );
    }

    return AnalysisResult(
      concentration: json['concentration']?.toDouble(),
      colorInfo: json['color_info'] != null
          ? ColorInfo.fromJson(json['color_info'])
          : null,
      processedImage: processedImage,
    );
  }
}

class ColorInfo {
  final double? l;
  final double? a;
  final double? b;

  ColorInfo({this.l, this.a, this.b});

  factory ColorInfo.fromJson(Map<String, dynamic> json) {
    return ColorInfo(
      l: json['L']?.toDouble(),
      a: json['a']?.toDouble(),
      b: json['b']?.toDouble(),
    );
  }
}

class ErrorScreen extends StatelessWidget {
  final String error;

  const ErrorScreen({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 50, color: Colors.red),
            const SizedBox(height: 20),
            const Text('发生错误', style: TextStyle(fontSize: 24)),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 30),
            ElevatedButton(
              onPressed: () => Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const CameraScreen()),
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}