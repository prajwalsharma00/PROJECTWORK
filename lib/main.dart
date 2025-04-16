import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

// Global value notifier to hold the current theme mode for toggling.
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

void main() {
  runApp(const TodoApp());
}

class TodoApp extends StatelessWidget {
  const TodoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, currentMode, _) {
        return MaterialApp(
          title: 'Todo List',
          // Light theme
          theme: ThemeData(
            brightness: Brightness.light,
            primarySwatch: Colors.blue,
            scaffoldBackgroundColor: Colors.grey[50],
            visualDensity: VisualDensity.adaptivePlatformDensity,
          ),
          // Dark theme with improved background and text colors
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF121212),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF1F1F1F),
            ),
            cardColor: const Color(0xFF2A2A2A),
            textTheme: ThemeData.dark().textTheme.copyWith(
              // Adjust as desired for better contrast
              bodyLarge: const TextStyle(color: Colors.white),
              bodyMedium: const TextStyle(color: Colors.white70),
              titleLarge: const TextStyle(color: Colors.white),
              titleMedium: const TextStyle(color: Colors.white70),
            ),
          ),
          themeMode: currentMode,
          debugShowCheckedModeBanner: false,
          home: const SplashScreen(),
        );
      },
    );
  }
}

/// SplashScreen that covers the whole page with an image from 'assets/todolist.png'
/// After a short delay, navigates to the TodoHomePage.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    // Show splash for 2 seconds, then navigate.
    Timer(const Duration(seconds: 2), () {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const TodoHomePage()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SizedBox.expand(
        child: Image.asset(
          'assets/todolist.png',
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

/// Main Todo Home Page with server sync, local storage, connectivity,
/// and a theme toggle button in the AppBar.
class TodoHomePage extends StatefulWidget {
  const TodoHomePage({super.key});

  @override
  _TodoHomePageState createState() => _TodoHomePageState();
}

class _TodoHomePageState extends State<TodoHomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  List<Task> _allTasks = [];
  String _serverAddress = '10.0.2.2';
  String _serverPort = '11111';
  bool _isConnected = false;
  bool _isLoading = false;
  bool _hasPendingSync = false;
  final List<Task> _pendingSyncTasks = [];
  late StreamSubscription<ConnectivityResult> _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);
    _initConnectivity();
    _loadConfig();
    _loadLocalData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription.cancel();
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkConnectivityAndSync();
    }
  }

  void _initConnectivity() {
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((ConnectivityResult result) {
          if (result != ConnectivityResult.none) {
            _checkConnectivityAndSync();
          } else {
            setState(() => _isConnected = false);
          }
        });
  }

  Future<void> _checkConnectivityAndSync() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult != ConnectivityResult.none) {
      setState(() => _isConnected = true);
      if (_hasPendingSync) await _syncPendingTasks();
      await _syncWithServer();
    } else {
      setState(() => _isConnected = false);
    }
  }

  Future<void> _loadConfig() async {
    try {
      final config = await rootBundle.loadString('assets/config.txt');
      final parts = config.split(':');
      if (parts.length == 2) {
        setState(() {
          _serverAddress = parts[0].trim();
          _serverPort = parts[1].trim();
        });
      }
    } catch (e) {
      debugPrint('Error loading config: $e');
    }
  }

  Future<void> _loadLocalData() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/tasks.json');
    if (await file.exists()) {
      final contents = await file.readAsString();
      setState(() {
        _allTasks = (json.decode(contents) as List)
            .map((item) => Task.fromJson(item))
            .toList();
      });
    }
  }

  Future<void> _saveLocalData() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/tasks.json');
    await file.writeAsString(
      json.encode(_allTasks.map((task) => task.toJson()).toList()),
    );
  }

  Future<String> _recvData(Socket socket) async {
    final buffer = StringBuffer();
    await for (final chunk in socket.cast<List<int>>().transform(utf8.decoder)) {
      buffer.write(chunk);
      if (buffer.toString().contains('|END')) {
        break;
      }
    }
    final data = buffer.toString();
    final endIndex = data.indexOf('|END');
    if (endIndex != -1) {
      return data.substring(0, endIndex);
    }
    return data;
  }

  Future<String> _sendCommand(String command) async {
    String response = "";
    try {
      debugPrint('Sending command: $command');
      final socket = await Socket.connect(_serverAddress, int.parse(_serverPort))
          .timeout(const Duration(seconds: 5));
      socket.write(command);
      response = await _recvData(socket);
      debugPrint('Full response received:\n$response');
      socket.destroy();
    } catch (e) {
      debugPrint('Error in _sendCommand: $e');
      rethrow;
    }
    return response;
  }

  Future<void> _storeServerResponse(String response) async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/server_response.txt');
    await file.writeAsString(response);
  }

  Future<void> _syncPendingTasks() async {
    if (_pendingSyncTasks.isEmpty) return;
    setState(() => _isLoading = true);
    try {
      for (final task in _pendingSyncTasks) {
        if (task.isDeleted) {
          await _deleteTaskOnServer(task);
        } else if (task.isNew) {
          await _addTaskToServer(task);
        } else {
          await _updateTaskOnServer(task);
        }
      }
      setState(() {
        _pendingSyncTasks.clear();
        _hasPendingSync = false;
      });
    } catch (e) {
      debugPrint('Error syncing pending tasks: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _syncWithServer() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      final response = await _sendCommand('GETALL|END');
      await _storeServerResponse(response);
      int endIndex = response.indexOf('|END');
      if (endIndex == -1) {
        debugPrint(
          "Error: Server response doesn't contain '|END'. Using entire response.",
        );
        endIndex = response.length;
      }
      final rawData = response.substring(0, endIndex);
      debugPrint('Data used for parsing:\n$rawData');
      if (rawData.trim().isNotEmpty) {
        final serverTasks = _parseServerData(rawData);
        debugPrint('Parsed tasks:');
        for (final t in serverTasks) {
          debugPrint(t.toString());
        }
        setState(() {
          _allTasks = serverTasks;
          _isConnected = true;
        });
      } else {
        debugPrint('No tasks received from server; clearing current tasks.');
        setState(() {
          _allTasks = [];
        });
      }
      await _saveLocalData();
    } catch (e) {
      debugPrint('Connection error: $e');
      setState(() => _isConnected = false);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  List<Task> _parseServerData(String data) {
    final tasks = <Task>[];
    final lines = data.split(RegExp(r'[\r\n]+'));
    DateTime? currentDate;
    final dateHeaderRegex = RegExp(r'^DATE,(\d{7,8})$', caseSensitive: false);

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;
      final match = dateHeaderRegex.firstMatch(line);
      if (match != null) {
        String dateStr = match.group(1)!;
        if (dateStr.length == 7) {
          dateStr = "0$dateStr";
          debugPrint('Fixed 7-digit header to: $dateStr');
        }
        final formattedDate =
            "${dateStr.substring(0, 4)}-${dateStr.substring(4, 6)}-${dateStr.substring(6, 8)}";
        currentDate = DateTime.tryParse(formattedDate);
        if (currentDate == null) {
          debugPrint('Error parsing header date: $formattedDate. Skipping header.');
          continue;
        }
        debugPrint('Parsed header date: ${DateFormat('yyyy-MM-dd').format(currentDate)}');
        continue;
      }
      if (currentDate == null) continue;
      final lastCommaIndex = line.lastIndexOf(',');
      if (lastCommaIndex == -1) continue;
      final taskName = line.substring(0, lastCommaIndex).trim();
      final stateStr = line.substring(lastCommaIndex + 1).trim();
      if (taskName.isEmpty) continue;
      final isCompleted = stateStr.toLowerCase() == 'true';
      tasks.add(Task(
        name: taskName,
        date: currentDate,
        isCompleted: isCompleted,
        lastUpdated: DateTime.now(),
      ));
    }
    return tasks;
  }

  Future<void> _addTask(Task task) async {
    final newTask = task.copyWith(isNew: true, lastUpdated: DateTime.now());
    setState(() => _allTasks.add(newTask));
    await _saveLocalData();
    if (_isConnected) {
      await _addTaskToServer(newTask);
    } else {
      _pendingSyncTasks.add(newTask);
      setState(() => _hasPendingSync = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Task saved locally. Will sync when online')),
      );
    }
  }

  Future<void> _addTaskToServer(Task task) async {
    try {
      final dateStr = DateFormat('yyyyMMdd').format(task.date);
      final state = task.isCompleted ? 'true' : 'false';
      final command = 'ADD|DATE$dateStr|TASK${task.name}!STATE$state|END';
      final response = await _sendCommand(command);
      debugPrint('Add command response: $response');
      final updatedTask = task.copyWith(isNew: false);
      setState(() {
        _allTasks.remove(task);
        _allTasks.add(updatedTask);
      });
      await _saveLocalData();
    } catch (e) {
      debugPrint('Error adding task to server: $e');
      rethrow;
    }
  }

  Future<void> _updateTask(Task oldTask, Task newTask) async {
    final updatedTask = oldTask.copyWith(
      isCompleted: newTask.isCompleted,
      lastUpdated: DateTime.now(),
    );
    setState(() {
      _allTasks.remove(oldTask);
      _allTasks.add(updatedTask);
    });
    await _saveLocalData();
    if (_isConnected) {
      await _updateTaskOnServer(updatedTask);
    } else {
      _pendingSyncTasks.add(updatedTask);
      setState(() => _hasPendingSync = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Update saved locally. Will sync when online')),
      );
    }
  }

  Future<void> _updateTaskOnServer(Task task) async {
    try {
      final dateStr = DateFormat('yyyyMMdd').format(task.date);
      final state = task.isCompleted ? 'true' : 'false';
      final command = 'UPDATE|DATE$dateStr|TASK${task.name}!STATE$state|END';
      final response = await _sendCommand(command);
      debugPrint('Update command response: $response');
    } catch (e) {
      debugPrint('Error updating task on server: $e');
      rethrow;
    }
  }

  Future<void> _deleteTask(Task task) async {
    final deletedTask = task.copyWith(isDeleted: true, lastUpdated: DateTime.now());
    setState(() {
      _allTasks.remove(task);
      // Also remove any pending sync items that match this task
      _pendingSyncTasks.removeWhere((t) =>
      t.name.trim().toLowerCase() == task.name.trim().toLowerCase() &&
          DateFormat('yyyyMMdd').format(t.date) ==
              DateFormat('yyyyMMdd').format(task.date));
    });
    await _saveLocalData();
    if (_isConnected) {
      await _deleteTaskOnServer(deletedTask);
    } else {
      _pendingSyncTasks.add(deletedTask);
      setState(() => _hasPendingSync = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Deletion saved locally. Will sync when online')),
      );
    }
  }

  Future<void> _deleteTaskOnServer(Task task) async {
    try {
      final dateStr = DateFormat('yyyyMMdd').format(task.date);
      final state = task.isCompleted ? 'true' : 'false';
      final command = 'DELETE|DATE$dateStr|TASK${task.name}!STATE$state|END';
      final response = await _sendCommand(command);
      debugPrint('Delete command response: $response');
    } catch (e) {
      debugPrint('Error deleting task from server: $e');
      rethrow;
    }
  }

  List<Task> _getTodayTasks() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _allTasks.where((task) {
      final taskDate = DateTime(task.date.year, task.date.month, task.date.day);
      return taskDate.isAtSameMomentAs(today);
    }).toList();
  }

  List<Task> _getFutureTasks() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _allTasks.where((task) {
      final taskDate = DateTime(task.date.year, task.date.month, task.date.day);
      return taskDate.isAfter(today);
    }).toList();
  }

  List<Task> _getHistoryTasks() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return _allTasks.where((task) {
      final taskDate = DateTime(task.date.year, task.date.month, task.date.day);
      return taskDate.isBefore(today);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    // We dynamically swap out the gradient for the AppBar based on dark/light.
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final appBarGradient = isDarkMode
        ? const LinearGradient(
      colors: [Color(0xFF424242), Color(0xFF303030)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    )
        : const LinearGradient(
      colors: [Color(0xFF80DEEA), Color(0xFFE0F7FA)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Todo List'),
        flexibleSpace: Container(decoration: BoxDecoration(gradient: appBarGradient)),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Today'),
            Tab(text: 'History'),
            Tab(text: 'Future'),
          ],
        ),
        actions: [
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeNotifier,
            builder: (context, mode, _) {
              return IconButton(
                icon: Icon(mode == ThemeMode.dark
                    ? Icons.wb_sunny
                    : Icons.nightlight_round),
                tooltip: 'Toggle Theme Mode',
                onPressed: () {
                  themeNotifier.value =
                  (themeNotifier.value == ThemeMode.dark)
                      ? ThemeMode.light
                      : ThemeMode.dark;
                },
              );
            },
          ),
          if (_hasPendingSync)
            const Tooltip(
              message: 'Pending sync',
              child: Icon(Icons.sync_problem, color: Colors.orange),
            ),
          IconButton(
            icon: Icon(_isConnected ? Icons.cloud_done : Icons.cloud_off),
            onPressed: _syncWithServer,
            tooltip: 'Sync with server',
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: CircularProgressIndicator(),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _syncWithServer,
        child: TabBarView(
          controller: _tabController,
          children: [
            TodayTab(
              tasks: _getTodayTasks(),
              onAddTask: _showAddTaskDialog,
              onUpdateTask: _updateTask,
              onDeleteTask: _deleteTask,
            ),
            HistoryTab(
              tasks: _getHistoryTasks(),
              onUpdateTask: _updateTask,
            ),
            FutureTab(
              tasks: _getFutureTasks(),
              onDeleteTask: _deleteTask,
            ),
          ],
        ),
      ),
      floatingActionButton: _tabController.index == 0
          ? FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () => _showAddTaskDialog(context),
      )
          : null,
    );
  }

  Future<void> _showAddTaskDialog(BuildContext context) async {
    final nameController = TextEditingController();
    DateTime selectedDate = DateTime.now();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateSB) {
            return AlertDialog(
              title: const Text('Add New Task'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Task Name'),
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    title: Text(DateFormat('yyyyMMdd').format(selectedDate)),
                    trailing: const Icon(Icons.calendar_today),
                    onTap: () async {
                      final date = await showDatePicker(
                        context: ctx,
                        initialDate: selectedDate,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (date != null) {
                        setStateSB(() => selectedDate = date);
                      }
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: () => Navigator.pop(ctx),
                ),
                TextButton(
                  child: const Text('Add'),
                  onPressed: () {
                    if (nameController.text.isNotEmpty) {
                      Navigator.pop(ctx, {
                        'name': nameController.text,
                        'date': selectedDate,
                      });
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
    if (result != null) {
      final task = Task(
        name: result['name'],
        date: result['date'],
        lastUpdated: DateTime.now(),
      );
      await _addTask(task);
    }
  }
}

/// An animated card used for tasks (scale and opacity transitions).
class AnimatedTaskCard extends StatefulWidget {
  final Widget child;

  const AnimatedTaskCard({super.key, required this.child});

  @override
  _AnimatedTaskCardState createState() => _AnimatedTaskCardState();
}

class _AnimatedTaskCardState extends State<AnimatedTaskCard> {
  double _scale = 0.95;
  double _opacity = 0.0;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() {
          _scale = 1.0;
          _opacity = 1.0;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _opacity,
      duration: const Duration(milliseconds: 500),
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 500),
        child: widget.child,
      ),
    );
  }
}

/// Task model representing an item on the todo list.
class Task {
  final String name;
  final DateTime date;
  final bool isCompleted;
  final DateTime lastUpdated;
  final bool isNew;
  final bool isDeleted;

  Task({
    required this.name,
    required this.date,
    this.isCompleted = false,
    DateTime? lastUpdated,
    this.isNew = false,
    this.isDeleted = false,
  }) : lastUpdated = lastUpdated ?? DateTime.now();

  Task copyWith({
    String? name,
    DateTime? date,
    bool? isCompleted,
    DateTime? lastUpdated,
    bool? isNew,
    bool? isDeleted,
  }) {
    return Task(
      name: name ?? this.name,
      date: date ?? this.date,
      isCompleted: isCompleted ?? this.isCompleted,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      isNew: isNew ?? this.isNew,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'date': date.toIso8601String(),
    'isCompleted': isCompleted,
    'lastUpdated': lastUpdated.toIso8601String(),
    'isNew': isNew,
    'isDeleted': isDeleted,
  };

  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      name: json['name'],
      date: DateTime.parse(json['date']),
      isCompleted: json['isCompleted'] ?? false,
      lastUpdated: DateTime.parse(json['lastUpdated'] ?? DateTime.now().toString()),
      isNew: json['isNew'] ?? false,
      isDeleted: json['isDeleted'] ?? false,
    );
  }

  @override
  String toString() {
    return 'Task{name: $name, date: ${DateFormat("yyyyMMdd").format(date)}, isCompleted: $isCompleted}';
  }
}

/// TodayTab with dynamic gradients for dark/light mode.
class TodayTab extends StatelessWidget {
  final List<Task> tasks;
  final Function(BuildContext) onAddTask;
  final Function(Task, Task) onUpdateTask;
  final Function(Task) onDeleteTask;

  const TodayTab({
    super.key,
    required this.tasks,
    required this.onAddTask,
    required this.onUpdateTask,
    required this.onDeleteTask,
  });

  @override
  Widget build(BuildContext context) {
    final completedTasks = tasks.where((t) => t.isCompleted).toList();
    final pendingTasks = tasks.where((t) => !t.isCompleted).toList();

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _buildTaskSection(
            context,
            title: 'Pending Tasks',
            tasks: pendingTasks,
            isCompleted: false,
          ),
        ),
        SliverToBoxAdapter(
          child: _buildTaskSection(
            context,
            title: 'Completed Tasks',
            tasks: completedTasks,
            isCompleted: true,
          ),
        ),
      ],
    );
  }

  Widget _buildTaskSection(
      BuildContext context, {
        required String title,
        required List<Task> tasks,
        required bool isCompleted,
      }) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    // Choose gradient and border color based on isCompleted and theme mode.
    final List<Color> gradientColors = isCompleted
        ? (isDarkMode
        ? const [Color(0xFF388E3C), Color(0xFF2E7D32)]
        : const [Color(0xFFC8E6C9), Color(0xFFE8F5E9)])
        : (isDarkMode
        ? const [Color(0xFF37474F), Color(0xFF455A64)]
        : const [Color(0xFFB2EBF2), Color(0xFFE0F7FA)]);

    final Color borderColor = isCompleted
        ? (isDarkMode ? Colors.lightGreenAccent : Colors.green)
        : (isDarkMode ? Colors.tealAccent : Colors.cyan);

    return Container(
      margin: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: gradientColors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: borderColor,
              ),
            ),
          ),
          if (tasks.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('No tasks found'),
            )
          else
            ...tasks.map((task) => _buildTaskItem(task, isCompleted, context))
        ],
      ),
    );
  }

  Widget _buildTaskItem(Task task, bool isCompleted, BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    // Card color changes for pending vs completed in dark mode.
    final Color cardColor = isCompleted
        ? (isDarkMode ? Colors.green[800]! : Colors.green[100]!)
        : (isDarkMode ? Colors.blueGrey[800]! : Colors.cyan[100]!);

    return Dismissible(
      key: Key('${task.name}_${DateFormat('yyyyMMdd').format(task.date)}'),
      direction: DismissDirection.endToStart,
      background: Container(
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.8),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Confirm'),
            content: const Text('Are you sure you want to delete this task?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
      },
      onDismissed: (direction) => onDeleteTask(task),
      child: AnimatedTaskCard(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Card(
            color: cardColor,
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ListTile(
              leading: IconButton(
                icon: Icon(
                  isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: isCompleted ? Colors.greenAccent : Colors.white,
                ),
                onPressed: () {
                  final updatedTask = task.copyWith(
                    isCompleted: !isCompleted,
                    lastUpdated: DateTime.now(),
                  );
                  onUpdateTask(task, updatedTask);
                },
              ),
              title: Text(
                task.name,
                style: TextStyle(
                  decoration: isCompleted ? TextDecoration.lineThrough : null,
                  fontSize: 16,
                  color: Colors.white,
                ),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.white),
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Confirm'),
                      content: const Text('Are you sure you want to delete this task?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    onDeleteTask(task);
                  }
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// HistoryTab with dynamic gradients and grouping tasks by date.
class HistoryTab extends StatelessWidget {
  final List<Task> tasks;
  final Function(Task, Task) onUpdateTask;

  const HistoryTab({
    super.key,
    required this.tasks,
    required this.onUpdateTask,
  });

  @override
  Widget build(BuildContext context) {
    final groupedTasks = _groupTasksByDate(tasks);
    return CustomScrollView(
      slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate(
                (ctx, index) {
              final date = groupedTasks.keys.elementAt(index);
              final dateTasks = groupedTasks[date]!;
              final completedTasks = dateTasks.where((t) => t.isCompleted).toList();
              final pendingTasks = dateTasks.where((t) => !t.isCompleted).toList();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDateHeader(context, date),
                  if (pendingTasks.isNotEmpty)
                    _buildTaskSection(
                      context,
                      'Pending',
                      pendingTasks,
                      false,
                    ),
                  if (completedTasks.isNotEmpty)
                    _buildTaskSection(
                      context,
                      'Completed',
                      completedTasks,
                      true,
                    ),
                  const Divider(height: 32),
                ],
              );
            },
            childCount: groupedTasks.length,
          ),
        ),
      ],
    );
  }

  Widget _buildDateHeader(BuildContext context, DateTime date) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    // For the date header, we previously used teal gradient in light mode.
    final List<Color> headerColors = isDarkMode
        ? const [Color(0xFF424242), Color(0xFF303030)]
        : const [Color(0xFF80CBC4), Color(0xFFB2DFDB)];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: headerColors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      child: Text(
        DateFormat('yyyy-MM-dd - EEEE').format(date),
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildTaskSection(
      BuildContext context,
      String title,
      List<Task> tasks,
      bool isCompleted,
      ) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    // Choose gradient and border color
    final List<Color> gradientColors = isCompleted
        ? (isDarkMode
        ? const [Color(0xFF388E3C), Color(0xFF2E7D32)]
        : const [Color(0xFFC8E6C9), Color(0xFFE8F5E9)])
        : (isDarkMode
        ? const [Color(0xFF37474F), Color(0xFF455A64)]
        : const [Color(0xFFB2EBF2), Color(0xFFE0F7FA)]);

    final Color borderColor = isCompleted
        ? (isDarkMode ? Colors.lightGreenAccent : Colors.green)
        : (isDarkMode ? Colors.tealAccent : Colors.cyan);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: gradientColors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section title
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ...tasks.map((task) => _buildTaskItem(context, task, isCompleted)).toList(),
        ],
      ),
    );
  }

  Widget _buildTaskItem(BuildContext context, Task task, bool isCompleted) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final Color cardColor = isCompleted
        ? (isDarkMode ? Colors.green[800]! : Colors.green[100]!)
        : (isDarkMode ? Colors.blueGrey[800]! : Colors.cyan[100]!);

    return AnimatedTaskCard(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
        child: Card(
          color: cardColor,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ListTile(
            leading: Icon(
              isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
              color: isCompleted ? Colors.greenAccent : Colors.white,
            ),
            title: Text(
              task.name,
              style: TextStyle(
                decoration: isCompleted ? TextDecoration.lineThrough : null,
                color: Colors.white,
              ),
            ),
            onTap: () {
              final updatedTask = task.copyWith(
                isCompleted: !isCompleted,
                lastUpdated: DateTime.now(),
              );
              onUpdateTask(task, updatedTask);
            },
          ),
        ),
      ),
    );
  }

  Map<DateTime, List<Task>> _groupTasksByDate(List<Task> tasks) {
    final map = <DateTime, List<Task>>{};
    for (final task in tasks) {
      final date = DateTime(task.date.year, task.date.month, task.date.day);
      map.putIfAbsent(date, () => []).add(task);
    }
    // Sort dates descending
    final sortedKeys = map.keys.toList()..sort((a, b) => b.compareTo(a));
    return Map.fromEntries(sortedKeys.map((key) => MapEntry(key, map[key]!)));
  }
}

/// FutureTab with dynamic purple gradient grouping future tasks by date.
class FutureTab extends StatelessWidget {
  final List<Task> tasks;
  final Function(Task) onDeleteTask;

  const FutureTab({
    super.key,
    required this.tasks,
    required this.onDeleteTask,
  });

  @override
  Widget build(BuildContext context) {
    final groupedTasks = _groupTasksByDate(tasks);
    return CustomScrollView(
      slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate(
                (ctx, index) {
              final date = groupedTasks.keys.elementAt(index);
              final dateTasks = groupedTasks[date]!;
              return _buildDateExpansion(context, date, dateTasks);
            },
            childCount: groupedTasks.length,
          ),
        ),
      ],
    );
  }

  Widget _buildDateExpansion(BuildContext context, DateTime date, List<Task> tasks) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    // Purple gradient for future tasks
    final List<Color> dateGradientColors = isDarkMode
        ? const [Color(0xFF5E35B1), Color(0xFF4527A0)]
        : const [Color(0xFFD1C4E9), Color(0xFFEDE7F6)];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: dateGradientColors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.deepPurple, width: 2),
      ),
      child: ExpansionTile(
        collapsedIconColor: Colors.white,
        iconColor: Colors.white,
        title: Text(
          DateFormat('yyyy-MM-dd - EEEE').format(date),
          style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white),
        ),
        children: tasks.map((task) => _buildTaskItem(context, task)).toList(),
      ),
    );
  }

  Widget _buildTaskItem(BuildContext context, Task task) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final Color cardColor =
    isDarkMode ? Colors.deepPurple[700]! : Colors.deepPurple[100]!;

    return AnimatedTaskCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
        child: Card(
          color: cardColor,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ListTile(
            leading: const Icon(Icons.event, color: Colors.white),
            title: Text(
              task.name,
              style: TextStyle(
                decoration: task.isCompleted ? TextDecoration.lineThrough : null,
                color: Colors.white,
              ),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete, color: Colors.white),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Confirm Deletion'),
                    content: const Text('Are you sure you want to delete this task?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  onDeleteTask(task);
                }
              },
            ),
          ),
        ),
      ),
    );
  }

  Map<DateTime, List<Task>> _groupTasksByDate(List<Task> tasks) {
    final map = <DateTime, List<Task>>{};
    for (var task in tasks) {
      final date = DateTime(task.date.year, task.date.month, task.date.day);
      map.putIfAbsent(date, () => []).add(task);
    }
    // Sort ascending for future tasks
    final sortedKeys = map.keys.toList()..sort();
    return Map.fromEntries(sortedKeys.map((key) => MapEntry(key, map[key]!)));
  }
}
