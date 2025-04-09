import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';


void main() {
  runApp(const TodoApp());
}


class TodoApp extends StatelessWidget {
  const TodoApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Todo List',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const TodoHomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}


class TodoHomePage extends StatefulWidget {
  const TodoHomePage({super.key});
  @override
  _TodoHomePageState createState() => _TodoHomePageState();
}


class _TodoHomePageState extends State<TodoHomePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  List<Task> _allTasks = [];
  // Change this if needed (for Android emulator try "10.0.2.2").
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
      print('Error loading config: $e');
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
        json.encode(_allTasks.map((task) => task.toJson()).toList()));
  }


  /// Custom function to receive data from the socket.
  /// Accumulates UTF-8 decoded chunks until it finds the terminator "|END"
  /// and then returns the accumulated data (excluding "|END").
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


  /// Opens a new socket connection, sends [command], and returns the complete response.
  Future<String> _sendCommand(String command) async {
    String response = "";
    try {
      print('Sending command: $command');
      final socket = await Socket.connect(_serverAddress, 11111)
          .timeout(const Duration(seconds: 5));
      socket.write(command);
      response = await _recvData(socket);
      print('Full response received:\n$response');
      socket.destroy();
    } catch (e) {
      print('Error in _sendCommand: $e');
      rethrow;
    }
    return response;
  }


  /// Stores the raw server response to a file for debugging.
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
      print('Error syncing pending tasks: $e');
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
        print("Error: Server response doesn't contain '|END'. Using entire response.");
        endIndex = response.length;
      }
      final rawData = response.substring(0, endIndex);
      print('Data used for parsing:\n$rawData');


      // Even if rawData is empty, update _allTasks (to clear stale tasks)
      if (rawData.trim().isNotEmpty) {
        final serverTasks = _parseServerData(rawData);
        print('Parsed tasks:');
        serverTasks.forEach((t) => print(t));
        setState(() {
          _allTasks = serverTasks;
          _isConnected = true;
        });
      } else {
        print('No tasks received from server; clearing current tasks.');
        setState(() {
          _allTasks = [];
        });
      }
      await _saveLocalData();
    } catch (e) {
      print('Connection error: $e');
      setState(() => _isConnected = false);
    } finally {
      setState(() => _isLoading = false);
    }
  }


  /// Parses raw server data into a list of Task objects.
  List<Task> _parseServerData(String data) {
    final tasks = <Task>[];
    final lines = data.split(RegExp(r'[\r\n]+'));
    DateTime? currentDate;
    // Accept header lines starting with "DATE," followed by 7 or 8 digits.
    final dateHeaderRegex = RegExp(r'^DATE,(\d{7,8})$', caseSensitive: false);


    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;
      final match = dateHeaderRegex.firstMatch(line);
      if (match != null) {
        String dateStr = match.group(1)!;
        if (dateStr.length == 7) {
          // Pad the date string if needed.
          dateStr = "0" + dateStr;
          print('Fixed 7-digit header to: $dateStr');
        }
        // Reformat dateStr to "yyyy-MM-dd" format.
        final formattedDate = "${dateStr.substring(0,4)}-${dateStr.substring(4,6)}-${dateStr.substring(6,8)}";
        // Use DateTime.tryParse to convert the formatted string.
        currentDate = DateTime.tryParse(formattedDate);
        if (currentDate == null) {
          print('Error parsing header date: $formattedDate. Skipping header.');
          continue;
        }
        print('Parsed header date: ${DateFormat('yyyy-MM-dd').format(currentDate)}');
        continue; // Move to next line (task lines follow)
      }
      if (currentDate == null) continue; // Skip task lines if no header date has been set.
      // Expecting task lines formatted as: "<task description>,<state>"
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
          const SnackBar(content: Text('Task saved locally. Will sync when online')));
    }
  }


  Future<void> _addTaskToServer(Task task) async {
    try {
      final dateStr = DateFormat('yyyyMMdd').format(task.date);
      final state = task.isCompleted ? 'true' : 'false';
      final command = 'ADD|DATE$dateStr|TASK${task.name}!STATE$state|END';
      final response = await _sendCommand(command);
      print('Add command response: $response');
      final updatedTask = task.copyWith(isNew: false);
      setState(() {
        _allTasks.remove(task);
        _allTasks.add(updatedTask);
      });
      await _saveLocalData();
    } catch (e) {
      print('Error adding task to server: $e');
      rethrow;
    }
  }


  Future<void> _updateTask(Task oldTask, Task newTask) async {
    final updatedTask = oldTask.copyWith(
        isCompleted: newTask.isCompleted, lastUpdated: DateTime.now());
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
          const SnackBar(content: Text('Update saved locally. Will sync when online')));
    }
  }


  Future<void> _updateTaskOnServer(Task task) async {
    try {
      final dateStr = DateFormat('yyyyMMdd').format(task.date);
      final state = task.isCompleted ? 'true' : 'false';
      final command = 'UPDATE|DATE$dateStr|TASK${task.name}!STATE$state|END';
      final response = await _sendCommand(command);
      print('Update command response: $response');
    } catch (e) {
      print('Error updating task on server: $e');
      rethrow;
    }
  }


  Future<void> _deleteTask(Task task) async {
    final deletedTask = task.copyWith(isDeleted: true, lastUpdated: DateTime.now());
    setState(() {
      _allTasks.remove(task);
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
          const SnackBar(content: Text('Deletion saved locally. Will sync when online')));
    }
  }


  Future<void> _deleteTaskOnServer(Task task) async {
    try {
      final dateStr = DateFormat('yyyyMMdd').format(task.date);
      final state = task.isCompleted ? 'true' : 'false';
      final command = 'DELETE|DATE$dateStr|TASK${task.name}!STATE$state|END';
      final response = await _sendCommand(command);
      print('Delete command response: $response');
    } catch (e) {
      print('Error deleting task from server: $e');
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Todo List'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Today'),
            Tab(text: 'History'),
            Tab(text: 'Future'),
          ],
        ),
        actions: [
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
              onUpdateTask: _updateTask,
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


  /// Displays a dialog to add a new task; uses a StatefulBuilder so the chosen date persists.
  Future<void> _showAddTaskDialog(BuildContext context) async {
    final nameController = TextEditingController();
    DateTime selectedDate = DateTime.now();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
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
                        context: context,
                        initialDate: selectedDate,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (date != null) {
                        setState(() {
                          selectedDate = date;
                        });
                      }
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: () => Navigator.pop(context),
                ),
                TextButton(
                  child: const Text('Add'),
                  onPressed: () {
                    if (nameController.text.isNotEmpty) {
                      Navigator.pop(context, {
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


  factory Task.fromJson(Map<String, dynamic> json) => Task(
    name: json['name'],
    date: DateTime.parse(json['date']),
    isCompleted: json['isCompleted'],
    lastUpdated: DateTime.parse(json['lastUpdated']),
    isNew: json['isNew'] ?? false,
    isDeleted: json['isDeleted'] ?? false,
  );


  @override
  String toString() {
    return 'Task{name: $name, date: ${DateFormat("yyyyMMdd").format(date)}, isCompleted: $isCompleted}';
  }
}


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
    // Removed AnimatedSwitcher for simpler rebuilds.
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _buildTaskSection('Pending Tasks', pendingTasks, false, context),
        ),
        SliverToBoxAdapter(
          child: _buildTaskSection('Completed Tasks', completedTasks, true, context),
        ),
      ],
    );
  }


  Widget _buildTaskSection(String title, List<Task> tasks, bool isCompleted, BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: isCompleted ? Colors.green : Theme.of(context).primaryColor,
            ),
          ),
        ),
        if (tasks.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text('No tasks found'),
          )
        else
          ...tasks.map((task) => _buildTaskItem(task, isCompleted, context)).toList(),
      ],
    );
  }


  Widget _buildTaskItem(Task task, bool isCompleted, BuildContext context) {
    return Dismissible(
      key: Key('${task.name}_${DateFormat('yyyyMMdd').format(task.date)}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        return await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Confirm'),
            content: const Text('Are you sure you want to delete this task?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
      },
      onDismissed: (direction) => onDeleteTask(task),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: ListTile(
            leading: IconButton(
              icon: Icon(
                isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
                color: isCompleted ? Colors.green : Colors.grey,
              ),
              onPressed: () {
                final updatedTask = task.copyWith(
                    isCompleted: !isCompleted, lastUpdated: DateTime.now());
                onUpdateTask(task, updatedTask);
              },
            ),
            title: Text(
              task.name,
              style: TextStyle(
                  decoration: isCompleted ? TextDecoration.lineThrough : null,
                  fontSize: 16),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () async {
                final confirmed = await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Confirm'),
                    content: const Text('Are you sure you want to delete this task?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(true),
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
}


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
    // Removed AnimatedSwitcher to ensure rebuilds.
    return CustomScrollView(
      slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate(
                (context, index) {
              final date = groupedTasks.keys.elementAt(index);
              final dateTasks = groupedTasks[date]!;
              final completedTasks = dateTasks.where((t) => t.isCompleted).toList();
              final pendingTasks = dateTasks.where((t) => !t.isCompleted).toList();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      DateFormat('yyyy-MM-dd - EEEE').format(date),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (pendingTasks.isNotEmpty)
                    _buildTaskSection('Pending', pendingTasks, false, context),
                  if (completedTasks.isNotEmpty)
                    _buildTaskSection('Completed', completedTasks, true, context),
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


  Map<DateTime, List<Task>> _groupTasksByDate(List<Task> tasks) {
    final map = <DateTime, List<Task>>{};
    for (var task in tasks) {
      final date = DateTime(task.date.year, task.date.month, task.date.day);
      map.putIfAbsent(date, () => []).add(task);
    }
    final sortedKeys = map.keys.toList()..sort((a, b) => b.compareTo(a));
    return Map.fromEntries(sortedKeys.map((key) => MapEntry(key, map[key]!)));
  }


  Widget _buildTaskSection(String title, List<Task> tasks, bool isCompleted, BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16.0, top: 8.0, bottom: 8.0),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: isCompleted ? Colors.green : Colors.orange,
            ),
          ),
        ),
        ...tasks.map((task) => _buildTaskItem(task, isCompleted, context)).toList(),
      ],
    );
  }


  Widget _buildTaskItem(Task task, bool isCompleted, BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Material(
        borderRadius: BorderRadius.circular(8),
        elevation: 1,
        child: ListTile(
          leading: Icon(
            isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
            color: isCompleted ? Colors.green : Colors.grey,
          ),
          title: Text(
            task.name,
            style: TextStyle(
              decoration: isCompleted ? TextDecoration.lineThrough : null,
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
    );
  }
}


class FutureTab extends StatelessWidget {
  final List<Task> tasks;
  final Function(Task, Task) onUpdateTask;
  const FutureTab({
    super.key,
    required this.tasks,
    required this.onUpdateTask,
  });
  @override
  Widget build(BuildContext context) {
    final groupedTasks = _groupTasksByDate(tasks);
    // Removed AnimatedSwitcher for a clearer rebuild.
    return CustomScrollView(
      slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate(
                (context, index) {
              final date = groupedTasks.keys.elementAt(index);
              final dateTasks = groupedTasks[date]!;
              return ExpansionTile(
                title: Text(
                  DateFormat('yyyy-MM-dd - EEEE').format(date),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                children: dateTasks
                    .map((task) => _buildTaskItem(task, task.isCompleted, context))
                    .toList(),
              );
            },
            childCount: groupedTasks.length,
          ),
        ),
      ],
    );
  }


  Map<DateTime, List<Task>> _groupTasksByDate(List<Task> tasks) {
    final map = <DateTime, List<Task>>{};
    for (var task in tasks) {
      final date = DateTime(task.date.year, task.date.month, task.date.day);
      map.putIfAbsent(date, () => []).add(task);
    }
    final sortedKeys = map.keys.toList()..sort();
    return Map.fromEntries(sortedKeys.map((key) => MapEntry(key, map[key]!)));
  }


  Widget _buildTaskItem(Task task, bool isCompleted, BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Material(
        borderRadius: BorderRadius.circular(8),
        elevation: 1,
        child: ListTile(
          leading: Icon(
            isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
            color: isCompleted ? Colors.green : Colors.grey,
          ),
          title: Text(
            task.name,
            style: TextStyle(
              decoration: isCompleted ? TextDecoration.lineThrough : null,
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
    );
  }
}
