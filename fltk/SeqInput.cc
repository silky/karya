#include <FL/Fl.H>
#include <FL/Fl_Window.H>

#include "f_util.h"
#include "config.h"

#include "MsgCollector.h"
#include "SeqInput.h"


SeqInput::SeqInput(int X, int Y, int W, int H, bool do_expansion) :
    Fl_Input(W, Y, W, H), focus_color(210, 220, 255),
    proper_size(W, H), expanded(false), do_expansion(do_expansion)
{
    this->textsize(Config::font_size::input);
    this->box(FL_THIN_DOWN_BOX);
    this->callback(SeqInput::changed_cb, static_cast<void *>(this));
    this->when(FL_WHEN_RELEASE);
}


void
SeqInput::resize(int x, int y, int w, int h)
{
    // DEBUG("resize to " << Point(w, h));
    this->proper_size = Point(w, h);
    if (!this->expanded)
        Fl_Input::resize(x, y, w, h);
}


int
SeqInput::set_text(const char *text)
{
    this->value(text);
    // So inputs consistently display the same part of text.
    this->position(0);
}


int
SeqInput::handle(int evt)
{
    switch (evt) {
    case FL_KEYDOWN:
        if (Fl::event_key() == FL_Tab || Fl::event_key() == FL_Enter) {
            Fl::focus(this->window());
            return 1;
        }
        break;
    case FL_FOCUS:
        this->color(color_to_fl(this->focus_color));
        // TODO select all
        this->redraw();
        break;
    case FL_UNFOCUS:
        this->color(FL_WHITE);
        // Scroll back to the beginning so edit fields show a consistent part
        // of the text.
        this->position(0);
        this->redraw();
        break;
    }
    // TODO
    // change keymap:
    // ^A and cmd+a should select all
    // set callback to when(FL_WHEN_RELEASE)
    // or maybe some control keys unfocus but don't eat the event?
    int val = Fl_Input::handle(evt);
    // Returing 0 is how Fl_Input lets the parent group do keynav so its
    // arrow key refocus thing works.  Returing 1 disables that.
    // I still get 14 keyups on arrow keys.  FLTK I LOVE YOU TOO!
    if (evt == FL_KEYDOWN)
        val = 1;

    switch (evt) {
    case FL_FOCUS: case FL_KEYDOWN:
        this->expand();
        break;
    case FL_UNFOCUS:
        this->contract();
        break;
    }
    return val;
}


void
SeqInput::expand()
{
    if (!this->do_expansion)
        return;
    Point size(0, 0);
    fl_font(Config::font, Config::font_size::input);
    fl_measure(this->value(), size.x, size.y, false);

    size.x += 7;
    size.x = std::max(size.x, this->proper_size.x);
    if (this->window()) {
        // Don't get larger than the parent window.
        size.x = std::min(size.x, this->window()->w() - this->x());
    }
    size.y = this->proper_size.y;
    this->expanded = true;

    if (size.x != this->w()) {
        bool contraction = size.x < this->w();
        // DEBUG(show_widget(this) << " expand to " << size);
        // Bypass this->size, which sets proper_size.
        Fl_Input::resize(x(), y(), size.x, size.y);
        if (contraction) {
            this->redraw_neighbors();
        }
        this->redraw();
    }
}


void
SeqInput::contract()
{
    if (!this->do_expansion)
        return;
    // DEBUG(show_widget(this) << " contract to " << this->proper_size);
    this->expanded = false;
    if (this->w() != proper_size.x || this->h() != proper_size.y) {
        Fl_Input::resize(x(), y(), proper_size.x, proper_size.y);
        // Since I might have sized over my neighbors to the right, I'll go
        // redraw them.
        this->redraw_neighbors();
    }
}


void
SeqInput::redraw_neighbors()
{
    // Since expand() can inconsiderately walk all over its neighbors, I have
    // to redraw them when I contract() again.
    Fl_Group *parent = this->parent();
    ASSERT(parent);
    Rect me(rect(this));
    // DEBUG("me: " << me);
    for (int i = 0; i < parent->children(); i++) {
        Fl_Widget &sibling = *parent->child(i);
        if (sibling.x() > x() &&
                !(sibling.y() > me.b() || sibling.y() + sibling.h() < me.y))
        {
            // DEBUG("redraw sibling " << i << show_widget(&sibling));
            sibling.redraw();
        }
    }
}


void
SeqInput::changed_cb(Fl_Widget *_w, void *vp)
{
    SeqInput *self = static_cast<SeqInput *>(vp);
    // I only put SeqInputs in BlockViewWindows, so this should be safe.
    BlockViewWindow *view = static_cast<BlockViewWindow *>(self->window());
    for (int i = 0; i < view->block.tracks(); i++) {
        if (&view->block.track_at(i)->title_widget() == self) {
            global_msg_collector()->window_update(view, UiMsg::msg_input, i);
            return;
        }
    }
    global_msg_collector()->window_update(view, UiMsg::msg_input);
}
