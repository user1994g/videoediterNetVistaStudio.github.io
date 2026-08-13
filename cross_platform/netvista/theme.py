APP_STYLE = r"""
QWidget { background: #12151b; color: #e9edf2; font-family: Arial; font-size: 12px; }
QMainWindow, QDialog { background: #0d1015; }
QFrame#topBar, QFrame#dock, QFrame#timelineTools { background: #171b22; border-bottom: 1px solid #2b313b; }
QLabel#brand { color: #ff3945; font-size: 19px; font-weight: 700; }
QLabel#panelTitle { color: #aab3c0; font-size: 10px; font-weight: 700; }
QLabel#status { color: #96a0ae; padding: 6px 10px; }
QPushButton, QToolButton { background: #262c36; border: 1px solid #353d49; border-radius: 5px; padding: 7px 11px; }
QPushButton:hover, QToolButton:hover { background: #303845; border-color: #536174; }
QPushButton:checked { background: #304c70; border-color: #518bd0; color: white; }
QPushButton#primary { background: #2d71b8; border-color: #3d89d4; font-weight: 700; }
QPushButton#danger { color: #ff7a84; }
QLineEdit, QComboBox, QSpinBox, QDoubleSpinBox { background: #202630; border: 1px solid #343d49; border-radius: 4px; padding: 6px; }
QListWidget { background: #11151b; border: 0; border-right: 1px solid #2a3039; outline: none; }
QListWidget::item { padding: 9px 7px; border-bottom: 1px solid #232933; }
QListWidget::item:selected { background: #284c70; }
QSlider::groove:horizontal { height: 4px; background: #343c48; border-radius: 2px; }
QSlider::handle:horizontal { width: 13px; margin: -5px 0; background: #5b9de0; border-radius: 6px; }
QProgressBar { background: #202630; border: 1px solid #343d49; border-radius: 4px; text-align: center; }
QProgressBar::chunk { background: #2f83cc; }
QGroupBox { border: 1px solid #303743; border-radius: 7px; margin-top: 11px; padding-top: 12px; font-weight: 700; }
QGroupBox::title { subcontrol-origin: margin; left: 9px; padding: 0 5px; color: #9fabba; }
QScrollArea { border: 0; background: #101318; }
QSplitter::handle { background: #252b34; }
"""
