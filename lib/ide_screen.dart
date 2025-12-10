import 'package:flutter/material.dart';
import 'package:python_web_ide/widgets/keyboard_toolbar.dart';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'interop.dart' as interop;
import 'utils/code_examples.dart';
import 'utils/code_history.dart';
import 'dart:math' as math;
import '../services/pollinations_services.dart';
import '../services/prompt_history_service.dart';
import '../widgets/prompt_history_widget.dart';
import '../models/prompt_history.dart';

enum KeyboardPosition { aboveEditor, betweenEditorOutput, belowOutput }

class IDEScreen extends StatefulWidget {
  const IDEScreen({super.key});

  @override
  State<IDEScreen> createState() => _IDEScreenState();
}

class _IDEScreenState extends State<IDEScreen> {
  String _output = '';
  final Map<String, String> _editorOutputs = {};
  bool _isLoading = false;
  final double _editorHeightRatio = 0.6;
  bool _pyodideLoaded = false;
  final double _fontSize = 14.0;
  final Map<String, String> _lastText = {};
  final Map<String, CodeHistory> _codeHistories = {};
  String _currentTheme = 'vs-dark';
  final Map<String, String> _currentFileNames = {};
  bool _preventHistoryUpdate = false;

  String? _currentRunningEditorId;
  int numberOfStudents = 1; // Start with 1 editor by default

  // Keyboard dimensions
  static const double KEYBOARD_HEIGHT = 200.0;
  static const double KEYBOARD_MAX_WIDTH = 600.0;

  final List<String> _monacoElementIds = [
    'monaco-editor-container-1',
    'monaco-editor-container-2',
    'monaco-editor-container-3',
    'monaco-editor-container-4',
  ];

  final List<String> _monacoDivIds = [
    'monaco-editor-div-1',
    'monaco-editor-div-2',
    'monaco-editor-div-3',
    'monaco-editor-div-4',
  ];
  bool _monacoInitialized = false;
  bool _editorsNeedReinitialization = false;

  final List<String> _availableThemes = ['vs-dark', 'vs-light', 'hc-black'];

  final Map<String, bool> _canUndoCache = {};
  final Map<String, bool> _canRedoCache = {};
  final Map<String, bool> _autocompleteEnabledCache = {};
  final Map<String, bool> _isPrettifyingCache = {};

  final Map<String, int> _editorRollNumbers = {};
  final Set<int> _usedRollNumbers = {};
  final math.Random _random = math.Random();

  // Keyboard positioning - now per editor
  final Map<String, KeyboardPosition> _keyboardPositions = {};

  // Output expansion state - per editor
  final Map<String, bool> _outputExpanded = {};

  // Prevent multiple simultaneous Monaco initialization attempts
  bool _isInitializingMonaco = false;

  // Input management
  final TextEditingController _promptController = TextEditingController();
  final FocusNode _promptFocus = FocusNode();

  // State management
  bool _isGenerating = false;
  String? _errorMessage;

  // History management
  bool _showHistoryPanel = false;

  @override
  void initState() {
    super.initState();

    // Initialize state for each editor
    for (final id in _monacoDivIds) {
      _codeHistories[id] = CodeHistory();
      _lastText[id] = '';
      _currentFileNames[id] = 'untitled.py';
      _editorOutputs[id] = '';

      // Initialize undo/redo cache
      _updateUndoRedoCache(id);

      // Initialize autocomplete cache (enabled by default)
      _autocompleteEnabledCache[id] = true;
      _isPrettifyingCache[id] = false;

      // Initialize keyboard position for each editor
      _keyboardPositions[id] = KeyboardPosition.betweenEditorOutput;

      // Initialize output expansion state (collapsed by default)
      _outputExpanded[id] = false;

      _assignRollNumbers();
    }

    // Register view factories for ALL 4 editors upfront
    // This ensures they are available whenever we need them, not just on initial load
    for (var i = 0; i < 4; i++) {
      final elementId = _monacoElementIds[i];
      final divId = _monacoDivIds[i];

      // Clean up any existing DOM elements from previous sessions
      final existingElement = html.document.getElementById(divId);
      if (existingElement != null) {
        existingElement.remove();
        print('Cleaned up existing DOM element: $divId');
      }

      // Check if already registered to avoid duplicate registration
      try {
        ui_web.platformViewRegistry.registerViewFactory(
          elementId,
          (int viewId) =>
              html.DivElement()
                ..id = divId
                ..style.width = '100%'
                ..style.height = '100%',
        );
        print('Registered view factory for $elementId with div $divId');
      } catch (e) {
        print('View factory $elementId already registered or error: $e');
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Reduced delay since DOM elements are now always present
      Future.delayed(const Duration(milliseconds: 500), () {
        _setupMonacoEditor();
      });
      _initializePyodide();

      // Add visibility change listener to detect when user comes back to tab
      html.document.addEventListener('visibilitychange', (_) {
        if (!html.document.hidden!) {
          // Page became visible, check if editors need reinitialization
          // Add extra delay to ensure DOM is stable after page refresh
          Future.delayed(const Duration(milliseconds: 1000), () {
            // Only reinitialize if editors are actually missing or broken
            bool needsReinit = false;
            for (final id in _monacoDivIds) {
              final element = html.document.getElementById(id);
              if (element == null ||
                  (!element.hasAttribute('data-monaco-initialized') &&
                      element.children.isEmpty)) {
                needsReinit = true;
                print(
                  'Editor $id needs reinitialization after visibility change',
                );
                break;
              }
            }
            if (needsReinit) {
              _checkAndReinitializeEditors();
            }
          });
        }
      });
    });
  }

  @override
  void dispose() {
    _promptController.dispose();
    _promptFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Check if we need to reinitialize editors when coming back to the screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndReinitializeEditors();
    });
  }

  @override
  void didUpdateWidget(IDEScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Also check when the widget updates
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndReinitializeEditors();
    });
  }

  // Method to manually trigger reinitialization
  void _forceReinitializeEditors() {
    print('Forcing editor reinitialization...');
    _editorsNeedReinitialization = true;
    _checkAndReinitializeEditors();
  }

  void _checkAndReinitializeEditors() {
    // Check if any of the Monaco editor DOM elements are missing or improperly initialized
    bool needsReinit = false;

    for (final id in _monacoDivIds) {
      final element = html.document.getElementById(id);
      if (element == null) {
        needsReinit = true;
        print('Editor $id DOM element is missing');
        break;
      } else if (!element.hasAttribute('data-monaco-initialized') &&
          element.children.isEmpty) {
        needsReinit = true;
        print('Editor $id DOM element is empty and not initialized');
        break;
      }
    }

    if (needsReinit || _editorsNeedReinitialization) {
      print('Reinitializing Monaco editors...');
      _editorsNeedReinitialization = false;
      _monacoInitialized = false;

      Future.delayed(const Duration(milliseconds: 500), () {
        _setupMonacoEditor();
      });
    }
  }

  Future<void> _initializePyodide() async {
    // Define the callback function for Python output
    void onOutput(String message) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            // Add output to the active editor (you might want to track which editor is active)
            final activeEditorId =
                _currentRunningEditorId ??
                _monacoDivIds[0]; // or track active editor
            _editorOutputs[activeEditorId] =
                (_editorOutputs[activeEditorId] ?? '') + message;
          });
        }
      });
    }

    try {
      // Show a loading message in the output
      setState(() => _output = 'Initializing Python environment...\n');

      // Add timeout to prevent hanging
      String initMessage = await interop
          .initPyodide(onOutput)
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              throw Exception(
                'Pyodide initialization timed out after 30 seconds',
              );
            },
          );

      // Update the UI with the success message
      if (mounted) {
        setState(() {
          _output += '$initMessage\n\n';
          _pyodideLoaded = true; // Set the flag!
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _output += 'Error initializing Pyodide: $e\n');
      }
    }
  }

  void _setupMonacoEditor() {
    // Prevent multiple simultaneous initialization attempts
    if (_isInitializingMonaco) {
      print('Monaco initialization already in progress, skipping...');
      return;
    }

    _isInitializingMonaco = true;
    print('Starting Monaco editor setup...');

    const initialCode = '''# Welcome to Python Web IDE!
# Write your Python code here and click Run.

# Simple example
x = 2 + 3
print("Result:", x)

# Test function
def hello():
    return "Hello from Python!"

print(hello())
''';

    print('Setting up Monaco editors...'); // Debug log

    // Reset initialization flag
    _monacoInitialized = false;

    // Initialize all editors sequentially to avoid conflicts
    _initializeEditorsSequentially(initialCode);
  }

  Future<void> _initializeEditorsSequentially(String initialCode) async {
    // Shorter wait since DOM elements are now always present
    await Future.delayed(const Duration(milliseconds: 500));

    for (int i = 0; i < numberOfStudents; i++) {
      final id = _monacoDivIds[i];

      // Ensure state is initialized for this editor
      if (!_codeHistories.containsKey(id)) {
        _codeHistories[id] = CodeHistory();
        _currentFileNames[id] = 'untitled.py';
        _editorOutputs[id] = '';
        _autocompleteEnabledCache[id] = true;
        _isPrettifyingCache[id] = false;
        _keyboardPositions[id] = KeyboardPosition.betweenEditorOutput;
        _outputExpanded[id] = false;
      }

      _lastText[id] = initialCode;
      _codeHistories[id]?.addState(initialCode);

      // Check if DOM element exists before initializing
      print('Checking DOM element for $id...');

      try {
        // Wait for DOM element to be available with fewer retries since it should be there
        var retries = 0;
        while (retries < 10) {
          final element = html.document.getElementById(id);
          if (element != null) {
            // Check if Monaco editor already exists for this element
            final hasMonacoInstance = element.hasAttribute(
              'data-monaco-initialized',
            );

            if (hasMonacoInstance) {
              print(
                'Monaco editor already exists for $id, skipping initialization...',
              );
              break;
            }

            // Clear any existing content to prevent duplication
            element.innerHtml = '';
            print('DOM element found and cleared for $id, initializing...');
            break;
          }
          await Future.delayed(const Duration(milliseconds: 100));
          retries++;
        }

        if (retries >= 10) {
          print('DOM element $id not found after waiting ${retries * 100}ms');
          continue;
        }

        // Check again if element already has Monaco instance
        final element = html.document.getElementById(id);
        if (element != null &&
            !element.hasAttribute('data-monaco-initialized')) {
          await interop.initMonaco(
            id,
            initialCode,
            _currentTheme,
            _fontSize,
            (content) => _onContentChanged(content, id),
          );

          // Mark element as initialized
          element.setAttribute('data-monaco-initialized', 'true');
          print('Editor initialized: $id');
        }

        // Delay between initializations
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (error) {
        print('Error initializing editor $id: $error');
      }
    }

    if (mounted) {
      setState(() => _monacoInitialized = true);
    }

    // Reset the initialization flag
    _isInitializingMonaco = false;
    print('Monaco editor setup completed');
  }

  Future<void> _cleanupEditors() async {
    for (int i = 0; i < 4; i++) {
      // Clean up all 4 editors to be safe
      try {
        await interop.destroyEditor(_monacoDivIds[i]);

        // Also clear the DOM element and remove initialization marker to prevent duplication
        final element = html.document.getElementById(_monacoDivIds[i]);
        if (element != null) {
          element.innerHtml = '';
          element.removeAttribute('data-monaco-initialized');
          print('Cleared DOM element: ${_monacoDivIds[i]}');
        }
      } catch (error) {
        print('Error destroying editor ${_monacoDivIds[i]}: $error');
      }
    }
  }

  Future<void> _reinitializeEditors() async {
    setState(() {
      _monacoInitialized = false;
    });

    await _cleanupEditors();

    await Future.delayed(const Duration(milliseconds: 100));
    _setupMonacoEditor();
  }

  void _onContentChanged(String content, String editorId) {
    // Run in post-frame callback to avoid calling setState during a build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_preventHistoryUpdate && content != _lastText[editorId]) {
        _codeHistories[editorId]?.addState(content);
        _lastText[editorId] = content;

        _updateUndoRedoCache(editorId);
        setState(() {}); // Update Undo/Redo button states
      }
    });
  }

  Future<void> _runCode([String? editorId]) async {
    final id = editorId ?? _monacoDivIds[0];

    // Guard against running before Pyodide is loaded
    if (!_pyodideLoaded) {
      _showSnackBar('Python environment is still initializing. Please wait.');
      return;
    }
    _currentRunningEditorId = id;

    setState(() {
      _editorOutputs[id] = '';
      _isLoading = true;
    });

    try {
      final code = interop.getMonacoValue(id);
      final String? error = await interop.runPyodideCode(code);

      if (error != null && mounted) {
        setState(
          () => _editorOutputs[id] = '${_editorOutputs[id] ?? ''}\n$error',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _editorOutputs[id] =
                  '${_editorOutputs[id] ?? ''}\nExecution error: $e',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _currentRunningEditorId = null;
        });
      }
    }
  }

  int _generateUniqueRollNumber() {
    if (_usedRollNumbers.length >= 40) {
      return _random.nextInt(40) + 1;
    }
    int rollNumber;
    do {
      rollNumber = _random.nextInt(40) + 1; // Random number from 1 to 40
    } while (_usedRollNumbers.contains(rollNumber));

    _usedRollNumbers.add(rollNumber);
    return rollNumber;
  }

  void _assignRollNumbers() {
    _usedRollNumbers.clear();
    _editorRollNumbers.clear();

    for (int i = 0; i < numberOfStudents; i++) {
      final editorId = _monacoDivIds[i];
      _editorRollNumbers[editorId] = _generateUniqueRollNumber();
    }
  }

  void _regenerateRollNumber(String editorId) {
    // Remove current roll number from used set
    final currentRoll = _editorRollNumbers[editorId];
    if (currentRoll != null) {
      _usedRollNumbers.remove(currentRoll);
    }

    // Generate new unique roll number
    final newRollNumber = _generateUniqueRollNumber();

    setState(() {
      _editorRollNumbers[editorId] = newRollNumber;
    });
  }

  void _undo(String editorId) {
    final history = _codeHistories[editorId];
    if (history?.canUndo() == true) {
      _preventHistoryUpdate = true;
      final previousState = history!.undo();
      if (previousState != null) {
        interop.setEditorContent(editorId, previousState);
        _lastText[editorId] = previousState;
      }

      // Immediately update cache for instant UI response
      _updateUndoRedoCache(editorId);
      setState(() {});

      _preventHistoryUpdate = false;
    }
  }

  void _redo(String editorId) {
    final history = _codeHistories[editorId];
    if (history?.canRedo() == true) {
      _preventHistoryUpdate = true;
      final nextState = history!.redo();
      if (nextState != null) {
        interop.setEditorContent(editorId, nextState);
        _lastText[editorId] = nextState;
      }

      // Immediately update cache for instant UI response
      _updateUndoRedoCache(editorId);
      setState(() {});

      _preventHistoryUpdate = false;
    }
  }

  void _clearOutput([String? editorId]) {
    if (editorId != null) {
      setState(() => _editorOutputs[editorId] = '');
    } else {
      // Clear all outputs if no specific editor is specified
      setState(() {
        for (final id in _monacoDivIds) {
          _editorOutputs[id] = '';
        }
      });
    }
  }

  void _updateMonacoSettings([String? editorId]) {
    if (editorId != null) {
      interop.updateMonacoOptions(editorId, _currentTheme, _fontSize);
    } else {
      for (final id in _monacoDivIds) {
        interop.updateMonacoOptions(id, _currentTheme, _fontSize);
      }
    }
  }

  void _updateUndoRedoCache(String editorId) {
    _canUndoCache[editorId] = _codeHistories[editorId]?.canUndo() ?? false;
    _canRedoCache[editorId] = _codeHistories[editorId]?.canRedo() ?? false;
  }

  void _prettifyCode(String editorId) {
    setState(() {
      _isPrettifyingCache[editorId] = true;
    });

    Future.delayed(Duration(milliseconds: 100), () {
      interop.formatMonacoDocument(editorId);
      setState(() {
        _isPrettifyingCache[editorId] = false;
      });
    });
  }

  void _toggleAutocomplete(String editorId) {
    final isEnabled = _autocompleteEnabledCache[editorId] ?? true;
    _autocompleteEnabledCache[editorId] = !isEnabled;

    // Set autocomplete state
    interop.setAutocomplete(editorId, !isEnabled);

    // If enabling autocomplete, trigger suggestions to demonstrate functionality
    if (!isEnabled) {
      // Small delay to ensure settings are applied first
      Future.delayed(Duration(milliseconds: 100), () {
        interop.triggerAutocomplete(editorId);
      });
    }

    setState(() {}); // Update UI
  }

  void _loadExample(String exampleName, [String? editorId]) {
    final exampleCode = CodeExamples.examples[exampleName];
    if (exampleCode != null) {
      if (editorId != null) {
        interop.setMonacoValue(editorId, exampleCode);
        _lastText[editorId] = exampleCode;
        _codeHistories[editorId]?.clear();
        _codeHistories[editorId]?.addState(exampleCode);
        final fileName = '${exampleName.toLowerCase().replaceAll(' ', '_')}.py';
        setState(() => _currentFileNames[editorId] = fileName);
      } else {
        // Load in all editors
        for (final id in _monacoDivIds) {
          interop.setMonacoValue(id, exampleCode);
          _lastText[id] = exampleCode;
          _codeHistories[id]?.clear();
          _codeHistories[id]?.addState(exampleCode);
          final fileName =
              '${exampleName.toLowerCase().replaceAll(' ', '_')}.py';
          _currentFileNames[id] = fileName;
        }
        setState(() {});
      }
    }
  }

  // void _clearEditor(String? editorId) {
  //   showDialog(
  //     context: context,
  //     builder: (BuildContext context) {
  //       return AlertDialog(
  //         title: const Text('Clear Editor'),
  //         backgroundColor: Colors.grey[800],
  //         content: const Text(
  //           'Are you sure you want to clear all editor content? This action cannot be undone.',
  //           style: TextStyle(color: Colors.white),
  //         ),
  //         actions: [
  //           TextButton(
  //             onPressed: () => Navigator.of(context).pop(),
  //             child: const Text('Cancel'),
  //           ),
  //           ElevatedButton(
  //             onPressed: () {
  //               // Clear all editors
  //               for (final id in _monacoDivIds) {
  //                 interop.setMonacoValue(id, '');
  //                 _lastText[id] = '';
  //                 _codeHistories[id]?.clear();
  //                 _codeHistories[id]?.addState('');
  //                 _currentFileNames[id] = 'untitled.py';
  //               }
  //               setState(() {});
  //               Navigator.of(context).pop();
  //               _showSnackBar('Editors cleared');
  //             },
  //             style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
  //             child: const Text('Clear'),
  //           ),
  //         ],
  //       );
  //     },
  //   );
  // }

  void _changeTheme(String themeName) {
    setState(() {
      _currentTheme = themeName;
      _updateMonacoSettings();
    });
    _showSnackBar('Theme changed to $_currentTheme');
  }

  void _handleArrowUp(String editorId) {
    interop.moveCursor(editorId, 'up');
  }

  void _handleArrowDown(String editorId) {
    interop.moveCursor(editorId, 'down');
  }

  void _handleArrowLeft(String editorId) {
    interop.moveCursor(editorId, 'left');
  }

  void _handleArrowRight(String editorId) {
    interop.moveCursor(editorId, 'right');
  }

  void _saveCodeToFile([String? editorId]) {
    _showSaveDialog(editorId);
  }

  void _showSaveDialog([String? editorId]) {
    final id = editorId ?? _monacoDivIds[0];
    final TextEditingController fileNameController = TextEditingController(
      text: _currentFileNames[id] ?? 'untitled.py',
    );

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Save Python File'),
          backgroundColor: Colors.grey[800],
          content: TextField(
            controller: fileNameController,
            decoration: const InputDecoration(
              labelText: 'File name',
              hintText: 'Enter file name with .py extension',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                String fileName = fileNameController.text.trim();
                if (fileName.isEmpty) fileName = 'untitled.py';
                if (!fileName.endsWith('.py')) fileName += '.py';

                _downloadFile(fileName, interop.getMonacoValue(id));
                setState(() => _currentFileNames[id] = fileName);
                Navigator.of(context).pop();
                _showSnackBar('File saved as $fileName');
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _downloadFile(String fileName, String content) {
    final blob = html.Blob([content], 'text/plain');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute("download", fileName)
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        backgroundColor: Colors.blue[700],
      ),
    );
  }

  void _handleKeyPress(String key, String editorId) {
    // Insert the key at current cursor position
    interop.insertTextAtCursor(editorId, key);
  }

  void _handleBackspace(String editorId) {
    // Delete character before cursor
    interop.deleteCharacterBeforeCursor(editorId);
  }

  void _handleEnter(String editorId) {
    // Insert new line
    interop.insertTextAtCursor(editorId, '\n');
  }

  void _handleMenuSelection(String value, String editorId) {
    print('Menu selection: $value for editor: $editorId');
    print('Current position: ${_keyboardPositions[editorId]}');

    setState(() {
      switch (value) {
        case 'above':
          _keyboardPositions[editorId] = KeyboardPosition.aboveEditor;
          print('Setting position to: aboveEditor for $editorId');
          break;
        case 'between':
          _keyboardPositions[editorId] = KeyboardPosition.betweenEditorOutput;
          print('Setting position to: betweenEditorOutput for $editorId');
          break;
        case 'below':
          _keyboardPositions[editorId] = KeyboardPosition.belowOutput;
          print('Setting position to: belowOutput for $editorId');
          break;
      }
    });

    print('New position: ${_keyboardPositions[editorId]} for $editorId');
  }

  void _toggleOutputExpansion(String editorId) {
    setState(() {
      _outputExpanded[editorId] = !_outputExpanded[editorId]!;
    });
  }

  int _getOutputFlex(String editorId) {
    final baseFlex = ((1 - _editorHeightRatio) * 100).toInt();

    if (_outputExpanded[editorId] == true) {
      // When expanded, add approximate keyboard height
      return baseFlex + 25;
    }

    return baseFlex;
  }

  Widget _buildKeyboard(int editorIndex, {bool isSingleEditor = false}) {
    final keyboard = KeyboardToolbar(
      onKeyPress: (key) => _handleKeyPress(key, _monacoDivIds[editorIndex]),
      onBackspace: () => _handleBackspace(_monacoDivIds[editorIndex]),
      onEnter: () => _handleEnter(_monacoDivIds[editorIndex]),
      onUndo: () => _undo(_monacoDivIds[editorIndex]),
      onRedo: () => _redo(_monacoDivIds[editorIndex]),
      canUndo: _canUndoCache[_monacoDivIds[editorIndex]] ?? false,
      canRedo: _canRedoCache[_monacoDivIds[editorIndex]] ?? false,
      onArrowUp: () => _handleArrowUp(_monacoDivIds[editorIndex]),
      onArrowDown: () => _handleArrowDown(_monacoDivIds[editorIndex]),
      onArrowLeft: () => _handleArrowLeft(_monacoDivIds[editorIndex]),
      onArrowRight: () => _handleArrowRight(_monacoDivIds[editorIndex]),
      onPrettify: () => _prettifyCode(_monacoDivIds[editorIndex]),
      onToggleAutocomplete:
          () => _toggleAutocomplete(_monacoDivIds[editorIndex]),
      isAutocompleteEnabled:
          _autocompleteEnabledCache[_monacoDivIds[editorIndex]] ?? true,
      isPrettifying: _isPrettifyingCache[_monacoDivIds[editorIndex]] ?? false,
      onMenuSelection: _handleMenuSelection,
      editorId: _monacoDivIds[editorIndex],
    );

    // For single-editor mode, center the keyboard and constrain its width
    if (isSingleEditor) {
      return Center(
        child: SizedBox(
          width: KEYBOARD_MAX_WIDTH,
          height: KEYBOARD_HEIGHT,
          child: keyboard,
        ),
      );
    }

    // For multi-editor mode, use fixed height without expanding
    return SizedBox(height: KEYBOARD_HEIGHT, child: keyboard);
  }

  Widget _buildPromptInputSection() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'AI Text Generation',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _promptController,
                  focusNode: _promptFocus,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                  ),
                  decoration: InputDecoration(
                    hintText:
                        'Enter your prompt here (e.g., "Write a Python function to sort a list")',
                    hintStyle: TextStyle(color: Colors.grey[500], fontSize: 16),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey[400]!),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey[400]!),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: Colors.blue,
                        width: 2,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  maxLines: 3,
                  minLines: 1,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _generateTextFromPrompt(),
                  enabled: !_isGenerating,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _showHistory,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.grey[100],
                  padding: const EdgeInsets.all(16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.history, color: Colors.grey),
                tooltip: 'View prompt history',
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _isGenerating ? null : _generateTextFromPrompt,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child:
                    _isGenerating
                        ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            ),
                            SizedBox(width: 8),
                            Text('Generating...'),
                          ],
                        )
                        : const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.auto_awesome, size: 18),
                            SizedBox(width: 8),
                            Text('Generate'),
                          ],
                        ),
              ),
            ],
          ),
          if (_errorMessage != null) _buildErrorDisplay(),
        ],
      ),
    );
  }

  Future<void> _generateTextFromPrompt() async {
    final prompt = _promptController.text.trim();

    // Validate input
    if (prompt.isEmpty) {
      _showErrorMessage('Please enter a prompt');
      return;
    }

    // Update UI to show loading state
    setState(() {
      _isGenerating = true;
      _errorMessage = null;
    });

    try {
      // Generate multiple samples for different editors
      final int numEditors = numberOfStudents;
      final responses = await PollinationsServices.generateMultipleSamples(
        prompt: prompt,
        count: numEditors,
      );

      final List<String> generatedSamples = [];
      bool anySuccess = false;

      // Check responses and collect successful ones
      for (int i = 0; i < responses.length && i < numEditors; i++) {
        final response = responses[i];
        if (response.success && response.text.isNotEmpty) {
          generatedSamples.add(response.text);
          anySuccess = true;

          // Set the generated code in the corresponding editor
          final editorId = _monacoDivIds[i];
          interop.setMonacoValue(editorId, response.text);
          _lastText[editorId] = response.text;
          _codeHistories[editorId]?.clear();
          _codeHistories[editorId]?.addState(response.text);

          // Update filename to reflect the prompt
          final fileName = '${_sanitizeFilename(prompt)}_v${i + 1}.py';
          setState(() => _currentFileNames[editorId] = fileName);
        } else {
          // If generation failed for this editor, add error message
          generatedSamples.add(
            '# Error generating code: ${response.error ?? 'Unknown error'}',
          );
        }
      }

      if (anySuccess) {
        // Save to history
        await PromptHistoryService.savePrompt(
          prompt: prompt,
          responses: generatedSamples,
        );

        setState(() {
          _isGenerating = false;
          _errorMessage = null;
        });

        // Clear the input after successful generation
        _promptController.clear();

        // Show success feedback
        _showSuccessMessage('Code samples generated and loaded into editors!');
      } else {
        setState(() {
          _errorMessage = 'Failed to generate any code samples';
          _isGenerating = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Unexpected error: ${e.toString()}';
        _isGenerating = false;
      });
    }
  }

  // Helper method to sanitize filename
  String _sanitizeFilename(String prompt) {
    return prompt
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .replaceAll(RegExp(r'\s+'), '_')
        .substring(0, math.min(20, prompt.length));
  }

  // Load a prompt from history
  void _loadPromptFromHistory(PromptHistoryItem item) {
    setState(() {
      _promptController.text = item.prompt;
      _showHistoryPanel = false;

      if (item.responses.isNotEmpty) {
        final responses = item.responses;
        final numberOfResponses = responses.length;

        for (int i = 0; i < numberOfStudents && i < numberOfResponses; i++) {
          final editorId = _monacoDivIds[i];
          final response = responses[i];

          interop.setEditorContent(editorId, response);
          _lastText[editorId] = response;
          _codeHistories[editorId]?.addState(response);
          _updateUndoRedoCache(editorId);
          setState(() {
            _editorOutputs[editorId] = '';
          });
        }

        // Fill remaining editors with the last available response (not the first)
        if (numberOfResponses > 0 && numberOfResponses < numberOfStudents) {
          final lastResponse = responses[numberOfResponses - 1];
          for (int i = numberOfResponses; i < numberOfStudents; i++) {
            final editorId = _monacoDivIds[i];
            interop.setEditorContent(editorId, lastResponse);
            _lastText[editorId] = lastResponse;
            _codeHistories[editorId]?.addState(lastResponse);
            _updateUndoRedoCache(editorId);
            setState(() {
              _editorOutputs[editorId] = '';
            });
          }
        }
      }
    });
    _promptFocus.requestFocus();
  }

  // Show history panel
  void _showHistory() {
    setState(() {
      _showHistoryPanel = true;
    });
  }

  // Hide history panel
  void _hideHistory() {
    setState(() {
      _showHistoryPanel = false;
    });
  }

  // Helper method to show error messages
  void _showErrorMessage(String message) {
    setState(() {
      _errorMessage = message;
    });
  }

  void _showSuccessMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // Add this method for error display
  Widget _buildErrorDisplay() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.1),
        border: Border.all(color: Colors.red.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.red, fontSize: 14),
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _errorMessage = null;
              });
            },
            child: const Text('Dismiss', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    print('Building IDE with $numberOfStudents editors'); // Debug print
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Python Web IDE - $numberOfStudents Student${numberOfStudents == 1 ? '' : 's'}',
        ),
        backgroundColor: Colors.grey[900],
        actions: [
          PopupMenuButton<int>(
            onSelected: (value) async {
              setState(() {
                numberOfStudents = value;
              });
              _assignRollNumbers();
              await _reinitializeEditors();
            },
            itemBuilder:
                (context) => [
                  const PopupMenuItem<int>(
                    value: 0,
                    enabled: false,
                    child: Text(
                      'Number of Students',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const PopupMenuDivider(),
                  for (int i = 1; i <= 4; i++)
                    PopupMenuItem<int>(
                      value: i,
                      child: Row(
                        children: [
                          if (numberOfStudents == i)
                            const Icon(Icons.check, size: 16),
                          if (numberOfStudents == i) const SizedBox(width: 8),
                          Text('$i Student${i == 1 ? '' : 's'}'),
                        ],
                      ),
                    ),
                ],
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.palette),
            tooltip: 'Change Theme',
            onSelected: (value) {
              if (value != 'header') _changeTheme(value);
            },
            itemBuilder:
                (context) => [
                  const PopupMenuItem<String>(
                    value: 'header',
                    enabled: false,
                    child: Text(
                      'Editor Themes',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const PopupMenuDivider(),
                  ..._availableThemes.map(
                    (theme) =>
                        PopupMenuItem<String>(value: theme, child: Text(theme)),
                  ),
                ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reinitialize Editors',
            onPressed: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Reinitializing editors...'),
                  duration: Duration(seconds: 2),
                ),
              );
              await _reinitializeEditors();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Editors reinitialized successfully!'),
                    backgroundColor: Colors.green,
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.school),
            tooltip: 'Load Example',
            onSelected: (value) {
              if (value != 'header') _loadExample(value);
            },
            itemBuilder:
                (context) => [
                  const PopupMenuItem<String>(
                    value: 'header',
                    enabled: false,
                    child: Text(
                      'Code Examples',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const PopupMenuDivider(),
                  ...CodeExamples.examples.keys.map(
                    (example) => PopupMenuItem<String>(
                      value: example,
                      child: Text(example),
                    ),
                  ),
                ],
          ),
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Save File',
            onPressed: _saveCodeToFile,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showHistory,
        backgroundColor: Colors.blue,
        tooltip: 'Show Prompt History',
        child: const Icon(Icons.history),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              _buildPromptInputSection(),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Calculate responsive width for each editor
                    final availableWidth = constraints.maxWidth;
                    final margins =
                        (numberOfStudents - 1) * 8; // 4px margin on each side
                    final borders =
                        numberOfStudents * 4; // 2px border on each side
                    final editorWidth =
                        (availableWidth - margins - borders) / numberOfStudents;

                    // Minimum width to prevent editors from becoming too narrow
                    final minWidth = 300.0;
                    final useHorizontalScroll = editorWidth < minWidth;

                    // Calculate responsive width - always use horizontal scroll but with adaptive widths
                    final responsiveWidth =
                        useHorizontalScroll
                            ? minWidth
                            : (editorWidth - 8); // Account for margins

                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (int i = 0; i < numberOfStudents; i++)
                              Container(
                                width: responsiveWidth,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.blue.withOpacity(0.5),
                                    width: 2,
                                  ), // More visible border
                                  borderRadius: BorderRadius.circular(8),
                                  color:
                                      Colors
                                          .grey[850], // Background color to make containers visible
                                ),
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Column(
                                  key: ValueKey(
                                    'editor-column-${_monacoDivIds[i]}',
                                  ),
                                  children: [
                                    //Roll Number Header
                                    Container(
                                      height: 40, // Make header taller
                                      width: double.infinity,
                                      decoration: BoxDecoration(
                                        color: Colors.blue[700],
                                        border: const Border(
                                          bottom: BorderSide(
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ),
                                      child: Center(
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              'Editor ${i + 1} - Roll No: ${_editorRollNumbers[_monacoDivIds[i]] ?? 'N/A'}',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16, // Larger font
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            // Refresh button right beside the roll number
                                            GestureDetector(
                                              onTap:
                                                  () => _regenerateRollNumber(
                                                    _monacoDivIds[i],
                                                  ),
                                              child: Container(
                                                padding: const EdgeInsets.all(
                                                  2,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.white
                                                      .withOpacity(0.2),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: const Icon(
                                                  Icons.refresh,
                                                  color: Colors.white,
                                                  size: 14,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),

                                    // Show keyboard above editor if selected
                                    if (_keyboardPositions[_monacoDivIds[i]] ==
                                        KeyboardPosition.aboveEditor)
                                      _buildKeyboard(
                                        i,
                                        isSingleEditor: numberOfStudents == 1,
                                      ),

                                    // Editor section
                                    Expanded(
                                      key: ValueKey(
                                        'editor-expanded-${_monacoElementIds[i]}',
                                      ),
                                      flex: (_editorHeightRatio * 100).toInt(),
                                      child: Stack(
                                        key: ValueKey(
                                          'editor-stack-${_monacoElementIds[i]}',
                                        ),
                                        children: [
                                          HtmlElementView(
                                            key: ValueKey(_monacoElementIds[i]),
                                            viewType: _monacoElementIds[i],
                                          ),
                                          if (!_monacoInitialized)
                                            const Center(
                                              child:
                                                  CircularProgressIndicator(),
                                            ),
                                        ],
                                      ),
                                    ),

                                    // Show keyboard between editor and output if selected and output not expanded
                                    if (_keyboardPositions[_monacoDivIds[i]] ==
                                            KeyboardPosition
                                                .betweenEditorOutput &&
                                        _outputExpanded[_monacoDivIds[i]] !=
                                            true)
                                      _buildKeyboard(
                                        i,
                                        isSingleEditor: numberOfStudents == 1,
                                      ),

                                    const Divider(
                                      height: 1,
                                      color: Colors.grey,
                                    ),
                                    // Output section
                                    Expanded(
                                      key: ValueKey(
                                        'output-expanded-${_monacoElementIds[i]}',
                                      ),
                                      flex: _getOutputFlex(_monacoDivIds[i]),
                                      child: Container(
                                        key: ValueKey(
                                          'output-container-${_monacoElementIds[i]}',
                                        ),
                                        color: Colors.grey[900],
                                        padding: const EdgeInsets.all(8.0),
                                        child: Column(
                                          key: ValueKey(
                                            'output-column-${_monacoElementIds[i]}',
                                          ),
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Row(
                                              children: [
                                                const Icon(
                                                  Icons.terminal,
                                                  color: Colors.green,
                                                ),
                                                const SizedBox(width: 8),
                                                Text('Output ${i + 1}'),
                                                const Spacer(),
                                                IconButton(
                                                  icon: const Icon(
                                                    Icons.play_arrow,
                                                  ),
                                                  onPressed:
                                                      () => _runCode(
                                                        _monacoDivIds[i],
                                                      ),
                                                  tooltip: 'Run Code',
                                                ),
                                                IconButton(
                                                  icon: const Icon(Icons.clear),
                                                  onPressed:
                                                      () => _clearOutput(
                                                        _monacoDivIds[i],
                                                      ),
                                                  tooltip: 'Clear Output',
                                                ),
                                                IconButton(
                                                  icon: Icon(
                                                    _outputExpanded[_monacoDivIds[i]] ==
                                                            true
                                                        ? Icons
                                                            .keyboard_arrow_down
                                                        : Icons
                                                            .keyboard_arrow_up,
                                                  ),
                                                  onPressed:
                                                      () =>
                                                          _toggleOutputExpansion(
                                                            _monacoDivIds[i],
                                                          ),
                                                  tooltip:
                                                      _outputExpanded[_monacoDivIds[i]] ==
                                                              true
                                                          ? 'Collapse'
                                                          : 'Expand',
                                                ),
                                              ],
                                            ),
                                            const Divider(color: Colors.grey),
                                            Expanded(
                                              child: SingleChildScrollView(
                                                child: SelectableText(
                                                  _editorOutputs[_monacoDivIds[i]]
                                                              ?.isEmpty ??
                                                          true
                                                      ? 'Output will appear here...'
                                                      : _editorOutputs[_monacoDivIds[i]] ??
                                                          '',
                                                  style: TextStyle(
                                                    color:
                                                        (_editorOutputs[_monacoDivIds[i]] ??
                                                                    '')
                                                                .contains(
                                                                  'Error',
                                                                )
                                                            ? Colors.red
                                                            : Colors.white,
                                                    fontFamily: 'monospace',
                                                    fontSize: 14,
                                                  ),
                                                ),
                                              ),
                                            ),
                                            if (_isLoading)
                                              const LinearProgressIndicator(
                                                minHeight: 2,
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),

                                    // Show keyboard below output if selected and output not expanded
                                    if (_keyboardPositions[_monacoDivIds[i]] ==
                                            KeyboardPosition.belowOutput &&
                                        _outputExpanded[_monacoDivIds[i]] !=
                                            true)
                                      _buildKeyboard(
                                        i,
                                        isSingleEditor: numberOfStudents == 1,
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          // History panel overlay - moved outside Column and directly inside Stack
          if (_showHistoryPanel)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.5),
                child: Center(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return Container(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth * 0.9,
                          maxHeight: constraints.maxHeight * 0.8,
                        ),
                        child: PromptHistoryWidget(
                          onPromptSelected: (String prompt) {
                            // Find the full PromptHistoryItem by prompt text
                            // This is a temporary workaround - ideally the widget should pass the full item
                            PromptHistoryService.getHistory().then((items) {
                              final item = items.firstWhere(
                                (item) => item.prompt == prompt,
                                orElse:
                                    () => PromptHistoryItem(
                                      id: '',
                                      prompt: prompt,
                                      timestamp: DateTime.now(),
                                      responses: [],
                                    ),
                              );
                              _loadPromptFromHistory(item);
                            });
                          },
                          onClose: _hideHistory,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    ); // Close the Scaffold
  }
}
