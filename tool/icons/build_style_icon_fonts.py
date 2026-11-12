#!/usr/bin/env python3
"""Builds the icon fonts of the Android and iOS styles:

    assets/fonts/app_icons_material.ttf    Material icons (Apache 2.0)
    assets/fonts/app_icons_cupertino.ttf   CupertinoIcons (MIT)

Like app_icons.ttf (build_icon_font.py) each one is Lucide's light weight with
some glyphs drawn anew, at Lucide's own code points, so that loaded under
Lucide's font name (lib/core/theme/icon_strokes.dart) it changes every
`LucideIcons.x` in the app without touching the code. MATERIAL and CUPERTINO
below give each Lucide icon the app uses its closest match; one missing there,
or set to None, stays Lucide's light glyph.

Sources, both already on a machine that builds the app:
- Material: the Material Icons font in the Flutter SDK
  (bin/cache/artifacts/material_fonts/materialicons-regular.otf, from
  google/material-design-icons), named as in its codepoints file (Flutter's
  `Icons.x`, but 3d_rotation for threed_rotation). The `_rounded`
  ones are Material's Round theme; outlines come from its `*_outline` and
  `*_border` icons, or the Outlined theme, which is what Material Symbols
  Rounded at its default (unfilled) setting looks like.
- Cupertino: CupertinoIcons.ttf from the cupertino_icons package in the pub
  cache, named as Flutter's `CupertinoIcons.x`. Never Apple's SF Symbols.

A name may end in |fliph, |flipv or |rot90 (a quarter turn clockwise) for an
icon that only exists the other way round.

    pip install fonttools picosvg
    python tool/icons/build_style_icon_fonts.py [--report]

Run it from the repo's root. --report also lists the Lucide icons used in lib/
that fall back to Lucide.
"""
import glob
import os
import re
import shutil
import sys

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.reverseContourPen import ReverseContourPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

from build_icon_font import lucide_package

# Lucide's name: Flutter's Icons name.
MATERIAL = {
    'aArrowDown': 'text_decrease_rounded',
    'aArrowUp': 'text_increase_rounded',
    'aLargeSmall': 'format_size_rounded',
    'alignCenter': 'format_align_center_rounded',
    'alignJustify': 'format_align_justify_rounded',
    'alignLeft': 'format_align_left_rounded',
    'alignRight': 'format_align_right_rounded',
    'appWindow': 'web_asset_rounded',
    'archive': 'archive_outlined',
    'arrowDown': 'arrow_downward_rounded',
    'arrowDownAZ': 'sort_by_alpha_rounded',
    'arrowDownToLine': 'vertical_align_bottom_rounded',
    'arrowDownWideNarrow': 'sort_rounded',
    'arrowDownZA': 'sort_by_alpha_rounded',
    'arrowLeft': 'arrow_back_rounded',
    'arrowLeftFromLine': 'start_rounded|fliph',
    'arrowRight': 'arrow_forward_rounded',
    'arrowRightFromLine': 'start_rounded',
    'arrowRightToLine': 'keyboard_tab_rounded',
    'arrowUp': 'arrow_upward_rounded',
    'arrowUpDown': 'swap_vert_rounded',
    'arrowUpNarrowWide': 'sort_rounded|flipv',
    'arrowUpToLine': 'vertical_align_top_rounded',
    'audioLines': 'graphic_eq_rounded',
    'axis3d': 'view_in_ar_outlined',
    'ban': 'block_rounded',
    'baseline': 'text_format_rounded',
    'betweenHorizontalEnd': None,
    'betweenHorizontalStart': None,
    'betweenVerticalEnd': None,
    'betweenVerticalStart': None,
    'binary': None,
    'blend': 'opacity_rounded',
    'bluetooth': 'bluetooth_rounded',
    'bold': 'format_bold_rounded',
    'bookImage': 'photo_album_outlined',
    'bookOpen': 'import_contacts_outlined',
    'bookOpenText': 'menu_book_outlined',
    'bookX': None,
    'bookmark': 'bookmark_border_rounded',
    'bookmarkCheck': 'bookmark_added_outlined',
    'bookmarkMinus': 'bookmark_remove_outlined',
    'bookmarkPlus': 'bookmark_add_outlined',
    'box': 'view_in_ar_outlined',
    'braces': 'data_object_rounded',
    'calendarClock': 'calendar_month_outlined',
    'camera': 'photo_camera_outlined',
    'captions': 'closed_caption_outlined',
    'captionsOff': 'closed_caption_disabled_outlined',
    'caseSensitive': 'text_fields_rounded',
    'chartColumn': 'bar_chart_rounded',
    'check': 'check_rounded',
    'chevronDown': 'expand_more_rounded',
    'chevronLeft': 'chevron_left_rounded',
    'chevronRight': 'chevron_right_rounded',
    'chevronUp': 'expand_less_rounded',
    'chevronsUpDown': 'unfold_more_rounded',
    'circle': 'radio_button_unchecked_rounded',
    'circleAlert': 'error_outline_rounded',
    'circleArrowDown': 'arrow_circle_down_outlined',
    'circleCheck': 'check_circle_outline_rounded',
    'circleHelp': 'help_outline_rounded',
    'circleSlash': 'block_rounded',
    'circleStop': 'stop_circle_outlined',
    'circleX': 'highlight_off_rounded',
    'clapperboard': 'movie_outlined',
    'clipboardList': 'assignment_outlined',
    'clipboardPaste': 'content_paste_rounded',
    'cloud': 'cloud_outlined',
    'cloudDownload': 'cloud_download_outlined',
    'code': 'code_rounded',
    'columns2': 'vertical_split_outlined',
    'columns3': 'view_column_outlined',
    'contrast': 'contrast_rounded',
    'copy': 'content_copy_outlined',
    'copyPlus': 'library_add_outlined',
    'cornerDownLeft': 'keyboard_return_rounded',
    'cpu': 'memory_rounded',
    'crop': 'crop_rounded',
    'decimalsArrowLeft': None,
    'decimalsArrowRight': None,
    'dices': 'casino_outlined',
    'download': 'download_outlined',
    'droplet': 'water_drop_outlined',
    'droplets': 'water_drop_outlined',
    'ellipsis': 'more_horiz_rounded',
    'ellipsisVertical': 'more_vert_rounded',
    'eraser': None,
    'externalLink': 'open_in_new_rounded',
    'eye': 'visibility_outlined',
    'eyeOff': 'visibility_off_outlined',
    'file': 'insert_drive_file_outlined',
    'fileArchive': 'folder_zip_outlined',
    'fileAudio': 'audio_file_outlined',
    'fileCode': None,
    'fileCog': None,
    'fileImage': 'image_outlined',
    'fileInput': 'file_open_outlined',
    'fileJson': 'data_object_rounded',
    'fileOutput': 'output_rounded',
    'filePlus': 'note_add_outlined',
    'filePlus2': 'note_add_outlined',
    'fileSearch': 'find_in_page_outlined',
    'fileSpreadsheet': 'table_chart_outlined',
    'fileTerminal': 'terminal_rounded',
    'fileText': 'description_outlined',
    'fileType': 'font_download_outlined',
    'fileUp': 'upload_file_outlined',
    'fileWarning': None,
    'fileX': None,
    'fileX2': None,
    'files': 'file_copy_outlined',
    'film': 'theaters_outlined',
    # Lucide names these by their axis: flipVertical2 mirrors left and right.
    'flipHorizontal2': 'flip_rounded|rot90',
    'flipVertical2': 'flip_rounded',
    'folder': 'folder_outlined',
    'folderDown': None,
    'folderLock': None,
    'folderOpen': 'folder_open_outlined',
    'folderPlus': 'create_new_folder_outlined',
    'folderSearch': None,
    'folderX': 'folder_off_outlined',
    'galleryVertical': 'view_day_outlined',
    'galleryVerticalEnd': 'view_agenda_outlined',
    'gauge': 'speed_rounded',
    'globe': 'language_rounded',
    'grid2x2': 'window_outlined',
    'grid2x2X': 'grid_off_rounded',
    'grid3x3': 'grid_on_rounded',
    'gripVertical': 'drag_indicator_rounded',
    'hand': 'pan_tool_outlined',
    'hardDrive': 'storage_rounded',
    'hash': 'tag_rounded',
    'heading': 'title_rounded',
    'headphones': 'headphones_rounded',
    'heart': 'favorite_border_rounded',
    'highlighter': 'border_color_outlined',
    'history': 'history_rounded',
    'house': 'home_outlined',
    'image': 'image_outlined',
    'imageOff': 'hide_image_outlined',
    'imagePlus': 'add_photo_alternate_outlined',
    'images': 'photo_library_outlined',
    'inbox': 'inbox_outlined',
    'indentDecrease': 'format_indent_decrease_rounded',
    'indentIncrease': 'format_indent_increase_rounded',
    'info': 'info_outline_rounded',
    'italic': 'format_italic_rounded',
    'keyRound': 'key_outlined',
    'layers': 'layers_outlined',
    'layoutGrid': 'grid_view_outlined',
    'layoutList': 'view_list_outlined',
    'layoutTemplate': 'dashboard_outlined',
    'link': 'link_rounded',
    'list': 'list_rounded',
    'listChecks': 'checklist_rounded',
    'listOrdered': 'format_list_numbered_rounded',
    'listPlus': 'playlist_add_rounded',
    'listTree': 'account_tree_outlined',
    'listVideo': 'playlist_play_rounded',
    'listX': 'playlist_remove_rounded',
    'locateFixed': 'my_location_rounded',
    'lock': 'lock_outline_rounded',
    'lockKeyhole': 'lock_outline_rounded',
    'lockKeyholeOpen': 'lock_open_outlined',
    'lockOpen': 'lock_open_outlined',
    'maximize': 'fullscreen_rounded',
    'maximize2': 'open_in_full_rounded',
    'memoryStick': 'memory_rounded',
    'minimize': 'fullscreen_exit_rounded',
    'minimize2': 'close_fullscreen_rounded',
    'minus': 'remove_rounded',
    'monitor': 'desktop_windows_outlined',
    'monitorSmartphone': 'devices_rounded',
    'moon': 'dark_mode_outlined',
    'mousePointer2': 'near_me_outlined',
    'move3d': '3d_rotation_rounded',
    'music': 'music_note_rounded',
    'network': 'lan_outlined',
    'package': 'inventory_2_outlined',
    'packageOpen': 'unarchive_outlined',
    'paintBucket': 'format_color_fill_rounded',
    'palette': 'palette_outlined',
    'panelLeft': 'view_sidebar_outlined|fliph',
    'panelLeftClose': 'menu_open_rounded',
    'panelRight': 'view_sidebar_outlined',
    'panelTop': 'web_asset_rounded',
    'pause': 'pause_rounded',
    'penLine': 'edit_outlined',
    'penTool': 'draw_outlined',
    'pencil': 'edit_outlined',
    'pictureInPicture2': 'picture_in_picture_alt_outlined',
    'pin': 'push_pin_outlined',
    'play': 'play_arrow_rounded',
    'plus': 'add_rounded',
    'power': 'power_settings_new_rounded',
    'presentation': 'slideshow_outlined',
    'radar': 'radar_rounded',
    'radio': 'sensors_rounded',
    'radioTower': 'cell_tower_rounded',
    'rectangleVertical': 'crop_portrait_rounded',
    'redo2': 'redo_rounded',
    'refreshCcw': 'refresh_rounded|fliph',
    'refreshCw': 'refresh_rounded',
    'removeFormatting': 'format_clear_rounded',
    'repeat': 'repeat_rounded',
    'repeat1': 'repeat_one_rounded',
    'replace': 'find_replace_rounded',
    'rotate3d': '3d_rotation_rounded',
    'rotateCcw': 'rotate_left_rounded',
    'rotateCw': 'rotate_right_rounded',
    'rows3': 'table_rows_outlined',
    'ruler': 'straighten_rounded',
    'save': 'save_outlined',
    'scale': 'balance_rounded',
    'scaling': 'photo_size_select_large_rounded',
    'scan': 'crop_free_rounded',
    'scanText': 'document_scanner_outlined',
    'scissors': 'content_cut_rounded',
    'scrollText': 'article_outlined',
    'search': 'search_rounded',
    'searchX': 'search_off_rounded',
    'send': 'send_outlined',
    'server': 'dns_outlined',
    'settings': 'settings_outlined',
    'settings2': 'tune_rounded',
    'shapes': 'category_outlined',
    'share2': 'share_outlined',
    'sheet': 'table_view_outlined',
    'shieldAlert': 'gpp_maybe_outlined',
    'shieldCheck': 'verified_user_outlined',
    'shieldOff': 'remove_moderator_outlined',
    'shuffle': 'shuffle_rounded',
    'sigma': 'functions_rounded',
    'signature': 'gesture_rounded',
    'skipBack': 'skip_previous_rounded',
    'skipForward': 'skip_next_rounded',
    'slidersHorizontal': 'tune_rounded',
    'smartphone': 'smartphone_rounded',
    'snowflake': 'ac_unit_rounded',
    'sparkles': 'auto_awesome_outlined',
    'spline': 'polyline_outlined',
    'square': 'crop_square_rounded',
    'squareArrowOutUpRight': 'open_in_new_rounded',
    'squareDashed': 'highlight_alt_rounded',
    'squarePen': 'edit_note_rounded',
    'squarePlus': 'add_box_outlined',
    'star': 'star_border_rounded',
    'stickyNote': 'sticky_note_2_outlined',
    'strikethrough': 'strikethrough_s_rounded',
    'subscript': 'subscript_rounded',
    'sun': 'light_mode_outlined',
    'sunMoon': 'brightness_6_outlined',
    'superscript': 'superscript_rounded',
    'tableCellsMerge': 'call_merge_rounded',
    'tableCellsSplit': 'call_split_rounded',
    'terminal': 'terminal_rounded',
    'textCursorInput': 'text_fields_rounded',
    'textSearch': 'manage_search_rounded',
    'timer': 'timer_outlined',
    'timerOff': 'timer_off_outlined',
    'trash': 'delete_outline_rounded',
    'trash2': 'delete_outline_rounded',
    'triangleAlert': 'warning_amber_rounded',
    'tv': 'tv_rounded',
    'type': 'title_rounded',
    'underline': 'format_underlined_rounded',
    'undo2': 'undo_rounded',
    'unlink': 'link_off_rounded',
    'upload': 'upload_outlined',
    'usb': 'usb_rounded',
    'users': 'group_outlined',
    'video': 'videocam_outlined',
    'videoOff': 'videocam_off_outlined',
    'volume2': 'volume_up_rounded',
    'volumeX': 'volume_off_rounded',
    'wandSparkles': 'auto_fix_high_outlined',
    'wholeWord': None,
    'wifi': 'wifi_rounded',
    'wifiOff': 'wifi_off_rounded',
    'wrapText': 'wrap_text_rounded',
    'wrench': 'build_outlined',
    'x': 'close_rounded',
    'zap': 'bolt_rounded',
    'zoomIn': 'zoom_in_rounded',
    'zoomOut': 'zoom_out_rounded',
}

# Lucide's name: Flutter's CupertinoIcons name.
CUPERTINO = {
    'aArrowDown': None,
    'aArrowUp': None,
    'aLargeSmall': 'textformat_size',
    'alignCenter': 'text_aligncenter',
    'alignJustify': 'text_justify',
    'alignLeft': 'text_alignleft',
    'alignRight': 'text_alignright',
    'appWindow': 'macwindow',
    'archive': 'archivebox',
    'arrowDown': 'arrow_down',
    'arrowDownAZ': 'sort_down',
    'arrowDownToLine': 'arrow_down_to_line',
    'arrowDownWideNarrow': 'sort_down',
    'arrowDownZA': 'sort_up',
    'arrowLeft': 'arrow_left',
    'arrowLeftFromLine': None,
    'arrowRight': 'arrow_right',
    'arrowRightFromLine': None,
    'arrowRightToLine': 'arrow_right_to_line',
    'arrowUp': 'arrow_up',
    'arrowUpDown': 'arrow_up_arrow_down',
    'arrowUpNarrowWide': 'sort_up',
    'arrowUpToLine': 'arrow_up_to_line',
    'audioLines': 'waveform',
    'axis3d': 'view_3d',
    'ban': 'nosign',
    'baseline': 'textformat_abc_dottedunderline',
    'betweenHorizontalEnd': None,
    'betweenHorizontalStart': None,
    'betweenVerticalEnd': None,
    'betweenVerticalStart': None,
    'binary': 'textformat_123',
    'blend': 'circle_lefthalf_fill',
    'bluetooth': 'bluetooth',
    'bold': 'bold',
    'bookImage': 'book',
    'bookOpen': 'book',
    'bookOpenText': 'book',
    'bookX': None,
    'bookmark': 'bookmark',
    'bookmarkCheck': None,
    'bookmarkMinus': None,
    'bookmarkPlus': None,
    'box': 'cube',
    'braces': 'chevron_left_slash_chevron_right',
    'calendarClock': 'calendar',
    'camera': 'camera',
    'captions': 'captions_bubble',
    'captionsOff': None,
    'caseSensitive': 'textformat',
    'chartColumn': 'chart_bar',
    'check': 'checkmark',
    'chevronDown': 'chevron_down',
    'chevronLeft': 'chevron_left',
    'chevronRight': 'chevron_right',
    'chevronUp': 'chevron_up',
    'chevronsUpDown': 'chevron_up_chevron_down',
    'circle': 'circle',
    'circleAlert': 'exclamationmark_circle',
    'circleArrowDown': 'arrow_down_circle',
    'circleCheck': 'checkmark_circle',
    'circleHelp': 'question_circle',
    'circleSlash': 'slash_circle',
    'circleStop': 'stop_circle',
    'circleX': 'xmark_circle',
    'clapperboard': 'film',
    'clipboardList': 'doc_on_clipboard',
    'clipboardPaste': 'doc_on_clipboard',
    'cloud': 'cloud',
    'cloudDownload': 'cloud_download',
    'code': 'chevron_left_slash_chevron_right',
    'columns2': 'square_split_2x1',
    'columns3': 'rectangle_split_3x1',
    'contrast': 'circle_lefthalf_fill',
    'copy': 'doc_on_doc',
    'copyPlus': 'plus_square_on_square',
    'cornerDownLeft': 'return_icon',
    'cpu': None,
    'crop': 'crop',
    'decimalsArrowLeft': None,
    'decimalsArrowRight': None,
    'dices': None,
    'download': 'tray_arrow_down',
    'droplet': 'drop',
    'droplets': 'drop',
    'ellipsis': 'ellipsis',
    'ellipsisVertical': 'ellipsis_vertical',
    'eraser': None,
    'externalLink': 'arrow_up_right_square',
    'eye': 'eye',
    'eyeOff': 'eye_slash',
    'file': 'doc',
    'fileArchive': 'archivebox',
    'fileAudio': 'music_note',
    'fileCode': 'chevron_left_slash_chevron_right',
    'fileCog': 'gear_alt',
    'fileImage': 'photo',
    'fileInput': 'arrow_down_doc',
    'fileJson': 'chevron_left_slash_chevron_right',
    'fileOutput': 'arrow_up_doc',
    'filePlus': None,
    'filePlus2': None,
    'fileSearch': 'doc_text_search',
    'fileSpreadsheet': 'doc_chart',
    'fileTerminal': None,
    'fileText': 'doc_text',
    'fileType': 'textformat',
    'fileUp': 'arrow_up_doc',
    'fileWarning': None,
    'fileX': None,
    'fileX2': None,
    'files': 'doc_on_doc',
    'film': 'film',
    'flipHorizontal2': 'square_line_vertical_square|rot90',
    'flipVertical2': 'square_line_vertical_square',
    'folder': 'folder',
    'folderDown': 'folder',
    'folderLock': None,
    'folderOpen': 'folder_open',
    'folderPlus': 'folder_badge_plus',
    'folderSearch': None,
    'folderX': 'folder_badge_minus',
    'galleryVertical': 'rectangle_grid_1x2',
    'galleryVerticalEnd': 'rectangle_stack',
    'gauge': 'gauge',
    'globe': 'globe',
    'grid2x2': 'square_grid_2x2',
    'grid2x2X': None,
    'grid3x3': 'rectangle_split_3x3',
    'gripVertical': None,
    'hand': 'hand_raised',
    'hardDrive': None,
    'hash': 'number',
    'heading': None,
    'headphones': 'headphones',
    'heart': 'heart',
    'highlighter': 'paintbrush',
    'history': 'gobackward',
    'house': 'house',
    'image': 'photo',
    'imageOff': None,
    'imagePlus': None,
    'images': 'photo_on_rectangle',
    'inbox': 'tray',
    'indentDecrease': 'decrease_indent',
    'indentIncrease': 'increase_indent',
    'info': 'info_circle',
    'italic': 'italic',
    'keyRound': None,
    'layers': 'layers',
    'layoutGrid': 'square_grid_2x2',
    'layoutList': 'list_bullet',
    'layoutTemplate': 'rectangle_3_offgrid',
    'link': 'link',
    'list': 'list_bullet',
    'listChecks': 'text_badge_checkmark',
    'listOrdered': 'list_number',
    'listPlus': 'text_badge_plus',
    'listTree': 'list_bullet_indent',
    'listVideo': 'list_bullet_below_rectangle',
    'listX': 'text_badge_xmark',
    'locateFixed': 'scope',
    'lock': 'lock',
    'lockKeyhole': 'lock',
    'lockKeyholeOpen': 'lock_open',
    'lockOpen': 'lock_open',
    'maximize': 'fullscreen',
    'maximize2': 'arrow_up_left_arrow_down_right',
    'memoryStick': None,
    'minimize': 'fullscreen_exit',
    'minimize2': 'arrow_down_right_arrow_up_left',
    'minus': 'minus',
    'monitor': 'desktopcomputer',
    'monitorSmartphone': 'device_laptop',
    'moon': 'moon',
    'mousePointer2': 'cursor_rays',
    'move3d': 'move',
    'music': 'music_note',
    'network': 'flowchart',
    'package': 'cube_box',
    'packageOpen': 'tray_arrow_up',
    'paintBucket': 'paintbrush',
    'palette': 'color_filter',
    'panelLeft': 'sidebar_left',
    'panelLeftClose': 'sidebar_left',
    'panelRight': 'sidebar_right',
    'panelTop': 'rectangle_dock',
    'pause': 'pause',
    'penLine': 'pencil',
    'penTool': 'pencil_outline',
    'pencil': 'pencil',
    'pictureInPicture2': 'rectangle_on_rectangle',
    'pin': 'pin',
    'play': 'play',
    'plus': 'plus',
    'power': 'power',
    'presentation': 'rectangle_on_rectangle_angled',
    'radar': 'dot_radiowaves_right',
    'radio': 'dot_radiowaves_left_right',
    'radioTower': 'antenna_radiowaves_left_right',
    'rectangleVertical': 'rectangle|rot90',
    'redo2': 'arrow_uturn_right',
    'refreshCcw': 'arrow_counterclockwise',
    'refreshCw': 'arrow_clockwise',
    'removeFormatting': None,
    'repeat': 'repeat',
    'repeat1': 'repeat_1',
    'replace': 'arrow_2_squarepath',
    'rotate3d': None,
    'rotateCcw': 'rotate_left',
    'rotateCw': 'rotate_right',
    'rows3': 'line_horizontal_3',
    'ruler': None,
    'save': 'floppy_disk',
    'scale': None,
    'scaling': 'resize',
    'scan': 'viewfinder',
    'scanText': 'doc_text_viewfinder',
    'scissors': 'scissors',
    'scrollText': 'doc_plaintext',
    'search': 'search',
    'searchX': None,
    'send': 'paperplane',
    'server': None,
    'settings': 'gear',
    'settings2': 'slider_horizontal_3',
    'shapes': 'square_on_circle',
    'share2': 'square_arrow_up',
    'sheet': 'table',
    'shieldAlert': 'exclamationmark_shield',
    'shieldCheck': 'checkmark_shield',
    'shieldOff': 'shield_slash',
    'shuffle': 'shuffle',
    'sigma': 'sum',
    'signature': 'signature',
    'skipBack': 'backward_end',
    'skipForward': 'forward_end',
    'slidersHorizontal': 'slider_horizontal_3',
    'smartphone': 'device_phone_portrait',
    'snowflake': 'snow',
    'sparkles': 'sparkles',
    'spline': 'scribble',
    'square': 'square',
    'squareArrowOutUpRight': 'arrow_up_right_square',
    'squareDashed': None,
    'squarePen': 'square_pencil',
    'squarePlus': 'plus_square',
    'star': 'star',
    'stickyNote': 'square_list',
    'strikethrough': 'strikethrough',
    'subscript': 'textformat_subscript',
    'sun': 'sun_max',
    'sunMoon': 'circle_lefthalf_fill',
    'superscript': 'textformat_superscript',
    'tableCellsMerge': None,
    'tableCellsSplit': None,
    'terminal': None,
    'textCursorInput': 'text_cursor',
    'textSearch': 'doc_text_search',
    'timer': 'timer',
    'timerOff': None,
    'trash': 'trash',
    'trash2': 'trash',
    'triangleAlert': 'exclamationmark_triangle',
    'tv': 'tv',
    'type': 'textformat_alt',
    'underline': 'underline',
    'undo2': 'arrow_uturn_left',
    'unlink': None,
    'upload': 'tray_arrow_up',
    'usb': None,
    'users': 'person_2',
    'video': 'videocam',
    'videoOff': None,
    'volume2': 'speaker_2',
    'volumeX': 'speaker_slash',
    'wandSparkles': 'wand_stars',
    'wholeWord': 'textformat_abc_dottedunderline',
    'wifi': 'wifi',
    'wifiOff': 'wifi_slash',
    'wrapText': None,
    'wrench': 'wrench',
    'x': 'xmark',
    'zap': 'bolt',
    'zoomIn': 'zoom_in',
    'zoomOut': 'zoom_out',
}

# What the fonts' name tables say, for anyone who opens them.
LICENCE_NOTE = {
    'material': 'Lucide icons (ISC) with Material icons by Google (Apache License 2.0).',
    'cupertino': 'Lucide icons (ISC) with CupertinoIcons by the Flutter authors (MIT License).',
}


def flutter_root():
    flutter = shutil.which('flutter')
    if not flutter:
        sys.exit('flutter not found on the PATH')
    return os.path.dirname(os.path.dirname(os.path.realpath(flutter)))


def cupertino_package():
    cache = os.environ.get('PUB_CACHE') or os.path.join(os.environ.get('LOCALAPPDATA', os.path.expanduser('~/.pub-cache')), 'Pub', 'Cache')
    with open('pubspec.lock', encoding='utf-8') as f:
        version = re.search(r'\n  cupertino_icons:\n(?:    .*\n)*?    version: "([^"]+)"', f.read()).group(1)
    package = os.path.join(cache, 'hosted', 'pub.dev', f'cupertino_icons-{version}')
    if not os.path.isdir(package):
        sys.exit(f'{package} not found; run flutter pub get, or set PUB_CACHE')
    return package


def material_source():
    """The Material Icons font and Flutter's names for its icons."""
    fonts = os.path.join(flutter_root(), 'bin', 'cache', 'artifacts', 'material_fonts')
    names = {}
    with open(os.path.join(fonts, 'codepoints'), encoding='utf-8') as f:
        for line in f:
            name, code = line.split()
            names[name] = int(code, 16)
    return os.path.join(fonts, 'materialicons-regular.otf'), names


def cupertino_source():
    """CupertinoIcons.ttf and Flutter's names for its icons."""
    icons = os.path.join(flutter_root(), 'packages', 'flutter', 'lib', 'src', 'cupertino', 'icons.dart')
    with open(icons, encoding='utf-8') as f:
        names = {n: int(c, 16) for n, c in re.findall(r'static const IconData (\w+) = IconData\(\s*(0x[0-9a-fA-F]+)', f.read())}
    return os.path.join(cupertino_package(), 'assets', 'CupertinoIcons.ttf'), names


def used_icons():
    used = set()
    for path in glob.glob('lib/**/*.dart', recursive=True):
        with open(path, encoding='utf-8') as f:
            used.update(re.findall(r'LucideIcons\.(\w+)', f.read()))
    return used


def multiply(a, b):
    """The affine transform a after b, as fontTools' 6-tuples."""
    a1, a2, a3, a4, a5, a6 = a
    b1, b2, b3, b4, b5, b6 = b
    return (
        a1 * b1 + a3 * b2, a2 * b1 + a4 * b2,
        a1 * b3 + a3 * b4, a2 * b3 + a4 * b4,
        a1 * b5 + a3 * b6 + a5, a2 * b5 + a4 * b6 + a6,
    )


def turn(spec, cx, cy):
    """The flip or turn a mapping asks for, about (cx, cy)."""
    base = {
        'fliph': (-1, 0, 0, 1, 0, 0),
        'flipv': (1, 0, 0, -1, 0, 0),
        # A quarter turn clockwise, with y upward.
        'rot90': (0, -1, 1, 0, 0, 0),
    }[spec]
    to_origin = (1, 0, 0, 1, -cx, -cy)
    back = (1, 0, 0, 1, cx, cy)
    return multiply(back, multiply(base, to_origin))


def build(kind, mapping, source, names, output, codepoints, base_path, report):
    font = TTFont(base_path)
    cmap = font.getBestCmap()
    glyphs = font.getGlyphSet()
    glyf = font['glyf']
    hmtx = font['hmtx']
    size = font['head'].unitsPerEm

    src = TTFont(source)
    src_cmap = src.getBestCmap()
    src_glyphs = src.getGlyphSet()
    src_size = src['head'].unitsPerEm
    cubic = 'CFF ' in src

    missing = [f'{lucide}: {name}' for lucide, name in mapping.items()
               if name and name.split('|')[0] not in names]
    if missing:
        sys.exit(f'{kind}: no such icon:\n  ' + '\n  '.join(missing))
    unknown = [lucide for lucide in mapping if lucide not in codepoints]
    if unknown:
        sys.exit(f'{kind}: not a Lucide icon: {unknown}')

    for lucide, spec in mapping.items():
        if not spec:
            continue
        name, *turns = spec.split('|')
        glyph = src_glyphs[src_cmap[names[name]]]
        bounds = BoundsPen(src_glyphs)
        glyph.draw(bounds)
        x0, y0, x1, y1 = bounds.bounds
        if kind == 'material':
            # Drawn on a 24 px grid that fills the em, as Lucide's are; a
            # little bigger, as Material keeps a wider margin.
            cx = cy = src_size / 2
            scale = size / src_size * 1.04
        else:
            # Set like letters, on a baseline and as wide as each is: centred
            # in the em, at one size for all, and none much bigger than the em.
            cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
            scale = min(size / src_size * 1.05, size * 0.93 / max(x1 - x0, y1 - y0))
        transform = (1, 0, 0, 1, 0, 0)
        for t in turns:
            transform = multiply(turn(t, cx, cy), transform)
        transform = multiply((scale, 0, 0, scale, size / 2 - cx * scale, size / 2 - cy * scale), transform)
        mirrored = transform[0] * transform[3] - transform[1] * transform[2] < 0

        pen = TTGlyphPen(glyphs)
        target = Cu2QuPen(pen, max_err=0.6) if cubic else pen
        # TrueType draws outer contours clockwise; CFF the other way.
        if cubic != mirrored:
            target = ReverseContourPen(target)
        glyph.draw(TransformPen(target, transform))
        new = pen.glyph()
        name_in_font = cmap[codepoints[lucide]]
        glyf[name_in_font] = new
        new.recalcBounds(glyf)
        hmtx[name_in_font] = (hmtx[name_in_font][0], getattr(new, 'xMin', 0))

    names_table = font['name']
    for record in list(names_table.names):
        if record.nameID in (0, 13):
            names_table.removeNames(nameID=record.nameID)
    names_table.setName(LICENCE_NOTE[kind], 0, 3, 1, 0x409)
    names_table.setName(LICENCE_NOTE[kind], 13, 3, 1, 0x409)
    font.save(output)

    mapped = sorted(k for k, v in mapping.items() if v)
    print(f'{output}: {len(mapped)} icons from {os.path.basename(source)}, {os.path.getsize(output) // 1024} KB')
    if report:
        used = used_icons()
        fallback = sorted(n for n in used if not mapping.get(n))
        print(f'  used in lib/: {len(used)}; drawn from {kind}: {len(used) - len(fallback)}; Lucide: {len(fallback)}')
        print('  Lucide: ' + ', '.join(fallback))


def main():
    package = lucide_package()
    with open(os.path.join(package, 'lib', 'lucide_icons.dart'), encoding='utf-8') as f:
        codepoints = {
            name: int(code)
            for name, code in re.findall(r'static const IconData (\w+) = const IconData\(\s*(\d+)', f.read())
        }
    base = os.path.join(package, 'assets', 'build_font', 'LucideVariable-w300.ttf')
    report = '--report' in sys.argv
    material, material_names = material_source()
    build('material', MATERIAL, material, material_names, 'assets/fonts/app_icons_material.ttf', codepoints, base, report)
    cupertino, cupertino_names = cupertino_source()
    build('cupertino', CUPERTINO, cupertino, cupertino_names, 'assets/fonts/app_icons_cupertino.ttf', codepoints, base, report)


if __name__ == '__main__':
    main()
