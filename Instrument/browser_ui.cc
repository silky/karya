#include <FL/Fl.H>

#include "util.h"

#include "browser_ui.h"


const static int browser_width = 125;
const static int sb_width = 12;

enum { default_font_size = 12 };

int
BrowserInput::handle(int evt)
{
    if (evt == FL_KEYDOWN) {
        switch (Fl::event_key()) {
        case FL_Enter: case FL_KP_Enter:
            if (matches->value() != 0) {
                const char *text = matches->text(matches->value());
                this->msg_callback(msg_choose, text);
            }
            return 1;
        case FL_Down:
            this->matches->value(
                clamp(0, matches->size(), matches->value() + 1));
            matches->do_callback();
            return 1;
        case FL_Up:
            this->matches->value(
                clamp(0, matches->size(), matches->value() - 1));
            matches->do_callback();
            return 1;
        }
    }
    return Fl_Input::handle(evt);
}

Browser::Browser(int X, int Y, int W, int H, MsgCallback cb) :
    Fl_Tile::Fl_Tile(X, Y, W, H),
    info_pane(X+browser_width, Y, W-browser_width, H),
    select_pane(X, Y, browser_width, H),
        query(X, Y, browser_width, 20, &matches, cb),
        matches(X, Y+20, browser_width, H-20),

    msg_callback(cb)
{
    info_pane.box(FL_THIN_DOWN_BOX);
    info_pane.color(fl_rgb_color(0xff, 0xfd, 0xf0));
    info_pane.textsize(default_font_size);
    info_pane.scrollbar_width(sb_width);
    info_pane.buffer(this->info_buffer);
    info_pane.wrap_mode(true, 0); // Wrap at the edges.
    matches.color(fl_rgb_color(0xff, 0xfd, 0xf0));
    matches.box(FL_FLAT_BOX);
    matches.textsize(default_font_size);
    matches.scrollbar_width(sb_width);
    matches.callback(Browser::matches_cb, static_cast<void *>(this));

    query.color(fl_rgb_color(0xf0, 0xf0, 0xff));
    query.textsize(default_font_size);
    query.when(FL_WHEN_CHANGED);
    query.callback(Browser::query_cb, static_cast<void *>(this));

    select_pane.resizable(matches);

    Fl::focus(&query);
}

void
Browser::set_info(const char *info)
{
    this->info_buffer.text(info);
}


void
Browser::query_cb(Fl_Widget *_w, void *vp)
{
    Browser *self = static_cast<Browser *>(vp);
    self->msg_callback(msg_query, self->query.value());
}

void
Browser::matches_cb(Fl_Widget *w, void *vp)
{
    Browser *self = static_cast<Browser *>(vp);
    int n = self->matches.value();
    if (n != 0) {
        const char *text = self->matches.text(n);
        MsgType type;
        if (Fl::event() == FL_RELEASE && Fl::event_clicks() > 0)
            type = msg_choose;
        else
            type = msg_select;
        self->msg_callback(type, text);
    }
}


BrowserWindow::BrowserWindow(int X, int Y, int W, int H, const char *title,
        MsgCallback cb) :
    Fl_Double_Window(0, 0, W, H, title), browser(0, 0, W, H, cb)
{
    Fl::dnd_text_ops(false);
    Fl::visible_focus(false);
    this->resizable(this);
}
