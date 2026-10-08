from __future__ import annotations

import re
from typing import Any, Mapping


# These names intentionally match StudioTheme.swift so one declarative theme
# package can be installed on macOS, Windows, and Linux.
DEFAULT_THEME: dict[str, Any] = {
    "windowBackground": "#17191E",
    "topBarBackground": "#111317",
    "panelBackground": "#20232A",
    "workspaceBackground": "#181B21",
    "cardBackground": "#202833",
    "controlBackground": "#242A33",
    "primaryText": "#FFFFFF",
    "secondaryText": "#9DA6B5",
    "accent": "#F05B5E",
    "danger": "#ff7a84",
    "separator": "#363B46",
    "cornerRadius": 7.0,
}

_SAFE_COLOUR = re.compile(r"^#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?$")


def build_app_style(overrides: Mapping[str, Any] | None = None) -> str:
    """Build Qt styling from the same bounded tokens used by the Mac app."""
    theme = dict(DEFAULT_THEME)
    if overrides:
        for key, value in overrides.items():
            if key == "cornerRadius" and isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= float(value) <= 16:
                theme[key] = float(value)
            elif key in theme and isinstance(value, str) and _SAFE_COLOUR.fullmatch(value):
                theme[key] = value
    radius = theme["cornerRadius"]
    return f"""
QWidget {{ background: {theme['panelBackground']}; color: {theme['primaryText']}; font-family: Arial; font-size: 12px; }}
QMainWindow, QDialog {{ background: {theme['windowBackground']}; }}
QFrame#topBar, QFrame#dock, QFrame#timelineTools {{ background: {theme['topBarBackground']}; border-bottom: 1px solid {theme['separator']}; }}
QLabel#brand {{ color: {theme['primaryText']}; font-size: 17px; font-weight: 700; }}
QLabel#studio {{ color: {theme['accent']}; font-size: 10px; font-weight: 700; }}
QLabel#panelTitle {{ color: {theme['secondaryText']}; font-size: 10px; font-weight: 700; }}
QLabel#status {{ color: {theme['secondaryText']}; padding: 6px 10px; }}
QPushButton, QToolButton {{ background: {theme['controlBackground']}; border: 1px solid {theme['separator']}; border-radius: {radius}px; padding: 5px 9px; }}
QPushButton:hover, QToolButton:hover {{ background: {theme['cardBackground']}; border-color: {theme['accent']}; }}
QPushButton:checked, QToolButton:checked {{ background: {theme['accent']}; border-color: {theme['accent']}; color: {theme['primaryText']}; }}
QPushButton:disabled, QToolButton:disabled {{ color: {theme['secondaryText']}; }}
QPushButton#primary {{ background: {theme['accent']}; border-color: {theme['accent']}; font-weight: 700; }}
QPushButton#danger {{ color: {theme['danger']}; }}
QLineEdit, QComboBox, QSpinBox, QDoubleSpinBox {{ background: {theme['controlBackground']}; border: 1px solid {theme['separator']}; border-radius: {radius}px; padding: 6px; }}
QListWidget {{ background: {theme['windowBackground']}; border: 0; border-right: 1px solid {theme['separator']}; outline: none; }}
QListWidget::item {{ padding: 9px 7px; border-bottom: 1px solid {theme['separator']}; }}
QListWidget::item:selected {{ background: {theme['accent']}; }}
QSlider::groove:horizontal {{ height: 4px; background: {theme['separator']}; border-radius: 2px; }}
QSlider::handle:horizontal {{ width: 13px; margin: -5px 0; background: {theme['accent']}; border-radius: 6px; }}
QProgressBar {{ background: {theme['controlBackground']}; border: 1px solid {theme['separator']}; border-radius: {radius}px; text-align: center; }}
QProgressBar::chunk {{ background: {theme['accent']}; }}
QGroupBox {{ border: 1px solid {theme['separator']}; border-radius: {radius}px; margin-top: 11px; padding-top: 12px; font-weight: 700; }}
QGroupBox::title {{ subcontrol-origin: margin; left: 9px; padding: 0 5px; color: {theme['secondaryText']}; }}
QScrollArea {{ border: 0; background: {theme['workspaceBackground']}; }}
QSplitter::handle {{ background: {theme['topBarBackground']}; }}
"""


APP_STYLE = build_app_style()
