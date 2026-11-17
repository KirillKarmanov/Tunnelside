#!/usr/bin/env python3
"""Tunnelside for Linux: a window and a panel icon for the list of sites that go around the VPN."""
import json
import os
import sys
import threading

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3 as AppIndicator, Gdk, Gio, GLib, Gtk  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tunnelside_common import ServiceError, call  # noqa: E402

APP_ID = "io.github.kirillkarmanov.Tunnelside"
ICON_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons")
MENU_RULES = 25
KIND = {"domain": "домен", "ip": "IP", "subnet": "подсеть"}


def safe_call(command, **args):
    try:
        return call(command, **args), None
    except ServiceError as e:
        return None, str(e)


class RulesPage(Gtk.Box):
    def __init__(self, app):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=12)
        self.app = app
        add_row = Gtk.Box(spacing=6)
        self.target = Gtk.Entry(hexpand=True, placeholder_text="Сайт, ссылка или IP — можно несколько через пробел или запятую")
        self.target.connect("activate", self.on_add)
        self.note = Gtk.Entry(placeholder_text="Заметка", width_chars=16)
        self.note.connect("activate", self.on_add)
        add_btn = Gtk.Button(label="Добавить")
        add_btn.get_style_context().add_class("suggested-action")
        add_btn.connect("clicked", self.on_add)
        for w in (self.target, self.note, add_btn):
            add_row.pack_start(w, w is self.target, True, 0)
        self.message = Gtk.Label(xalign=0, wrap=True)
        self.search = Gtk.SearchEntry(placeholder_text="Найти в списке")
        self.search.connect("search-changed", lambda *_: self.fill(self.app.state))
        self.list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        self.list.set_placeholder(Gtk.Label(label="Исключений пока нет — добавьте сайт выше", margin=24))
        scroll = Gtk.ScrolledWindow(vexpand=True)
        scroll.add(self.list)
        for w in (add_row, self.message, self.search, scroll):
            self.pack_start(w, w is scroll, True, 0)

    def on_add(self, *_):
        text = self.target.get_text().strip()
        if not text:
            return
        answer, err = safe_call("add", text=text, note=self.note.get_text().strip())
        if err:
            self.say(err, error=True)
            return
        parts = []
        if answer["added"]:
            parts.append("Добавлено: " + ", ".join(answer["added"]))
        if answer["duplicates"]:
            parts.append("Уже в списке: " + ", ".join(answer["duplicates"]))
        if answer["invalid"]:
            parts.append("Не понял (нужен домен, ссылка, IPv4 или подсеть не шире /8): " + ", ".join(answer["invalid"]))
        self.say(". ".join(parts), error=bool(answer["invalid"]) and not answer["added"])
        if answer["added"]:
            self.target.set_text("")
            self.note.set_text("")
        self.app.refresh(force=True)

    def say(self, text, error=False):
        self.message.set_markup(f'<span foreground="#c01c28">{GLib.markup_escape_text(text)}</span>' if error
                                else GLib.markup_escape_text(text))

    def fill(self, state):
        for child in self.list.get_children():
            self.list.remove(child)
        if not state:
            return
        q = self.search.get_text().strip().lower()
        for rule in state["rules"]:
            if q and q not in rule["target"].lower() and q not in rule["note"].lower():
                continue
            self.list.add(self.make_row(rule))
        self.list.show_all()

    def make_row(self, rule):
        box = Gtk.Box(spacing=10, margin=6)
        switch = Gtk.Switch(active=rule["enabled"], valign=Gtk.Align.CENTER)
        switch.connect("notify::active", lambda s, _p: self.update(rule["id"], enabled=s.get_active()))
        texts = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        title = Gtk.Label(xalign=0, selectable=True)
        title.set_markup(f"<b>{GLib.markup_escape_text(rule['target'])}</b>  "
                         f"<small>{KIND.get(rule['kind'], '')}</small>")
        details = []
        if rule["note"]:
            details.append(rule["note"])
        if rule["error"]:
            details.append("⚠ " + rule["error"])
        elif rule["kind"] == "domain":
            details.append("адреса: " + (", ".join(rule["ips"]) if rule["ips"] else "ещё не получены"))
        sub = Gtk.Label(label=" · ".join(details), xalign=0, wrap=True, selectable=True)
        sub.get_style_context().add_class("dim-label")
        texts.pack_start(title, False, False, 0)
        texts.pack_start(sub, False, False, 0)
        note_btn = Gtk.Button.new_from_icon_name("document-edit-symbolic", Gtk.IconSize.BUTTON)
        note_btn.set_tooltip_text("Заметка")
        note_btn.connect("clicked", lambda *_: self.edit_note(rule))
        del_btn = Gtk.Button.new_from_icon_name("user-trash-symbolic", Gtk.IconSize.BUTTON)
        del_btn.set_tooltip_text("Удалить")
        del_btn.connect("clicked", lambda *_: self.delete(rule))
        box.pack_start(switch, False, False, 0)
        box.pack_start(texts, True, True, 0)
        box.pack_end(del_btn, False, False, 0)
        box.pack_end(note_btn, False, False, 0)
        return box

    def update(self, rid, **fields):
        _answer, err = safe_call("update", id=rid, **fields)
        if err:
            self.say(err, error=True)
        self.app.refresh(force=True)

    def edit_note(self, rule):
        dialog = Gtk.Dialog(title=f"Заметка — {rule['target']}", transient_for=self.app.window, modal=True)
        dialog.add_buttons("Отмена", Gtk.ResponseType.CANCEL, "Сохранить", Gtk.ResponseType.OK)
        entry = Gtk.Entry(text=rule["note"], activates_default=True, width_chars=40, margin=12)
        dialog.set_default_response(Gtk.ResponseType.OK)
        dialog.get_content_area().add(entry)
        dialog.show_all()
        if dialog.run() == Gtk.ResponseType.OK:
            self.update(rule["id"], note=entry.get_text().strip())
        dialog.destroy()

    def delete(self, rule):
        dialog = Gtk.MessageDialog(transient_for=self.app.window, modal=True, message_type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.NONE, text=f"Удалить {rule['target']}?")
        dialog.format_secondary_text("Сайт снова пойдёт через VPN.")
        dialog.add_buttons("Отмена", Gtk.ResponseType.CANCEL, "Удалить", Gtk.ResponseType.OK)
        if dialog.run() == Gtk.ResponseType.OK:
            _answer, err = safe_call("delete", id=rule["id"])
            self.say(err or f"Удалено: {rule['target']}", error=bool(err))
            self.app.refresh(force=True)
        dialog.destroy()


def text_view():
    view = Gtk.TextView(editable=False, monospace=True, wrap_mode=Gtk.WrapMode.WORD_CHAR, left_margin=8, top_margin=8)
    scroll = Gtk.ScrolledWindow(vexpand=True)
    scroll.add(view)
    return view, scroll


class CheckPage(Gtk.Box):
    def __init__(self):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=12)
        row = Gtk.Box(spacing=6)
        self.entry = Gtk.Entry(hexpand=True, placeholder_text="Домен, ссылка или IP — куда реально идёт и открывается ли")
        self.entry.connect("activate", self.on_check)
        self.button = Gtk.Button(label="Проверить")
        self.button.connect("clicked", self.on_check)
        row.pack_start(self.entry, True, True, 0)
        row.pack_start(self.button, False, False, 0)
        self.view, scroll = text_view()
        self.pack_start(row, False, False, 0)
        self.pack_start(scroll, True, True, 0)

    def on_check(self, *_):
        target = self.entry.get_text().strip()
        if not target:
            return
        self.button.set_sensitive(False)
        self.view.get_buffer().set_text("Проверяю…")

        def work():
            answer, err = safe_call("check", target=target)
            GLib.idle_add(self.show, answer, err)
        threading.Thread(target=work, daemon=True).start()

    def show(self, answer, err):
        self.button.set_sensitive(True)
        if err:
            self.view.get_buffer().set_text(err)
            return
        lines = [answer["target"], ""]
        if "direct_dns" in answer and (answer["direct_dns"] or answer.get("direct_dns_error")):
            lines.append("DNS сети (мимо VPN): " + (", ".join(answer["direct_dns"]) or answer.get("direct_dns_error", "")))
            lines.append("DNS системы:         " +(", ".join(answer["system_dns"]) or answer.get("system_dns_error", "")))
            lines.append("")
        for p in answer["paths"]:
            way = "через VPN" if p["dev"] == "wg0" else f"мимо VPN, через {p['via'] or p['dev']} ({p['dev']})"
            lines.append(f"{p['ip']}: {way}; порт 443 — {p['tcp']}")
        self.view.get_buffer().set_text("\n".join(lines))


class SettingsPage(Gtk.Grid):
    def __init__(self, app):
        super().__init__(row_spacing=10, column_spacing=12, margin=16)
        self.app = app
        self.pause = Gtk.Switch(halign=Gtk.Align.START)
        self.refresh_min = Gtk.SpinButton.new_with_range(1, 1440, 1)
        self.retention = Gtk.SpinButton.new_with_range(0, 168, 1)
        rows = [("Пауза (все сайты снова через VPN, список сохраняется)", self.pause),
                ("Обновлять адреса доменов, минут", self.refresh_min),
                ("Держать старый адрес домена после смены, часов", self.retention)]
        for i, (label, widget) in enumerate(rows):
            self.attach(Gtk.Label(label=label, xalign=0), 0, i, 1, 1)
            self.attach(widget, 1, i, 1, 1)
        save = Gtk.Button(label="Сохранить", halign=Gtk.Align.START)
        save.connect("clicked", self.on_save)
        self.attach(save, 1, len(rows), 1, 1)
        self.message = Gtk.Label(xalign=0)
        self.attach(self.message, 0, len(rows) + 1, 2, 1)

    def load(self, state):
        if state:
            self.pause.set_active(state["paused"])
            self.refresh_min.set_value(state["refresh_minutes"])
            self.retention.set_value(state["retention_hours"])

    def on_save(self, *_):
        _a, err = safe_call("settings", paused=self.pause.get_active(),
                            refresh_minutes=self.refresh_min.get_value_as_int(),
                            retention_hours=self.retention.get_value_as_int())
        self.message.set_text(err or "Сохранено")
        self.app.refresh(force=True)


class App(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID)
        self.window = None
        self.state = None
        self.state_key = None
        self.start_hidden = "--hidden" in sys.argv
        self.menu_busy = False

    def do_startup(self):
        Gtk.Application.do_startup(self)
        self.hold()  # keep running with the window closed: the panel icon stays
        self.build_window()
        self.indicator = AppIndicator.Indicator.new("tunnelside", "tunnelside",
                                                    AppIndicator.IndicatorCategory.APPLICATION_STATUS)
        self.indicator.set_icon_theme_path(ICON_DIR)
        self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.indicator.set_title("Tunnelside")
        self.menu = Gtk.Menu()
        self.indicator.set_menu(self.menu)
        self.refresh(force=True)
        GLib.timeout_add_seconds(4, self.refresh)

    def do_activate(self):
        if self.start_hidden:
            self.start_hidden = False
            return
        self.window.show_all()
        self.window.present()

    def build_window(self):
        self.window = Gtk.ApplicationWindow(application=self, title="Tunnelside — сайты мимо VPN")
        self.window.set_default_size(820, 580)
        self.window.set_icon_from_file(os.path.join(ICON_DIR, "tunnelside-app.png"))
        self.window.connect("delete-event", lambda w, _e: w.hide() or True)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.status_label = Gtk.Label(xalign=0, margin=10)
        self.rules = RulesPage(self)
        self.check = CheckPage()
        self.log_view, log_scroll = text_view()
        log_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin=12)
        log_btn = Gtk.Button(label="Обновить", halign=Gtk.Align.START)
        log_btn.connect("clicked", lambda *_: self.load_log())
        log_box.pack_start(log_btn, False, False, 0)
        log_box.pack_start(log_scroll, True, True, 0)
        self.settings = SettingsPage(self)
        notebook = Gtk.Notebook()
        for page, title in ((self.rules, "Исключения"), (self.check, "Проверка"),
                            (log_box, "Журнал"), (self.settings, "Настройки")):
            notebook.append_page(page, Gtk.Label(label=title))
        notebook.connect("switch-page", lambda _n, page, _i: page is log_box and self.load_log())
        box.pack_start(self.status_label, False, False, 0)
        box.pack_start(notebook, True, True, 0)
        self.window.add(box)

    def load_log(self):
        answer, err = safe_call("log")
        self.log_view.get_buffer().set_text(err or "\n".join(reversed(answer["lines"])))

    def refresh(self, force=False):
        state, err = safe_call("status")
        key = json.dumps(state, sort_keys=True) if state else err
        if force or key != self.state_key:
            self.state, self.state_key = state, key
            self.show_state(err)
        return True

    def show_state(self, err):
        s = self.state
        if err:
            status = f"⚠ {err}"
        else:
            on = sum(1 for r in s["rules"] if r["enabled"])
            status = (f"VPN: {s['vpn']} · исключений включено: {on} из {len(s['rules'])}"
                      + (" · ПАУЗА" if s["paused"] else "")
                      + (f" · сеть: шлюз {s['gateway']} ({s['device']})" if s["gateway"] else " · нет сети"))
        self.status_label.set_text(status)
        self.rules.fill(s)
        self.settings.load(s)
        good = s and s["vpn"] == "включён" and not s["paused"]
        self.indicator.set_icon_full("tunnelside" if good else "tunnelside-off", status)
        self.build_menu(status)

    def build_menu(self, status):
        self.menu_busy = True
        for child in self.menu.get_children():
            self.menu.remove(child)
        head = Gtk.MenuItem(label=status)
        head.set_sensitive(False)
        self.menu.append(head)
        add = Gtk.MenuItem(label="Добавить сайт из буфера обмена")
        add.connect("activate", self.add_from_clipboard)
        self.menu.append(add)
        open_item = Gtk.MenuItem(label="Открыть окно…")
        open_item.connect("activate", lambda *_: self.window.show_all() or self.window.present())
        self.menu.append(open_item)
        if self.state:
            self.menu.append(Gtk.SeparatorMenuItem())
            for rule in self.state["rules"][:MENU_RULES]:
                item = Gtk.CheckMenuItem(label=rule["target"] + (f" — {rule['note']}" if rule["note"] else ""))
                item.set_active(rule["enabled"])
                item.connect("toggled", self.on_menu_toggle, rule["id"])
                self.menu.append(item)
            if len(self.state["rules"]) > MENU_RULES:
                more = Gtk.MenuItem(label=f"…ещё {len(self.state['rules']) - MENU_RULES} — в окне")
                more.connect("activate", lambda *_: self.window.show_all() or self.window.present())
                self.menu.append(more)
            self.menu.append(Gtk.SeparatorMenuItem())
            pause = Gtk.CheckMenuItem(label="Пауза — всё через VPN")
            pause.set_active(self.state["paused"])
            pause.connect("toggled", self.on_menu_pause)
            self.menu.append(pause)
        quit_item = Gtk.MenuItem(label="Закрыть значок (исключения продолжат работать)")
        quit_item.connect("activate", lambda *_: self.quit())
        self.menu.append(quit_item)
        self.menu.show_all()
        self.menu_busy = False

    def on_menu_toggle(self, item, rid):
        if not self.menu_busy:
            safe_call("update", id=rid, enabled=item.get_active())
            GLib.idle_add(self.refresh, True)

    def on_menu_pause(self, item):
        if not self.menu_busy:
            safe_call("settings", paused=item.get_active())
            GLib.idle_add(self.refresh, True)

    def add_from_clipboard(self, *_):
        text = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).wait_for_text() or ""
        answer, err = safe_call("add", text=text.strip()[:2000])
        if err:
            body = err
        elif answer["added"]:
            body = "Мимо VPN: " + ", ".join(answer["added"])
        elif answer["duplicates"]:
            body = "Уже в списке: " + ", ".join(answer["duplicates"])
        else:
            body = "В буфере нет сайта или IP" + (f": {text.strip()[:60]}" if text.strip() else "")
        note = Gio.Notification.new("Tunnelside")
        note.set_body(body)
        self.send_notification(None, note)
        self.refresh(force=True)


if __name__ == "__main__":
    sys.exit(App().run([a for a in sys.argv if a != "--hidden"]))
