#include <algorithm>
#include <FL/Fl_Window.H>

#include "util.h"
#include "f_util.h"

#include "MoveTile.h"

#define DEBUG(X) ;


// Only resize widgets along the right and bottom edges.
// This is so that the tile proportions don't all grow when the widget grows.
void
MoveTile::resize(int x, int y, int w, int h)
{
    DEBUG("resize " << rect(this) << " to " << Rect(x, y, w, h));
    // Only resize the rightmost and bottommost widgets.  Shrink them down to 1
    // if necessary, but stop resizing children beyond that.
    Point edge(0, 0);
    for (int i = 0; i < this->children(); i++) {
        Rect c = rect(child(i));
        edge.x = std::max(edge.x, c.r());
        edge.y = std::max(edge.y, c.b());
    }
    Point translate(x - this->x(), y - this->y());
    for (int i = 0; i < this->children(); i++) {
        Rect c = rect(child(i));
        Rect new_c = c;
        new_c.translate(translate);
        // Resize down to 1 pixel minimum, not 0.  0 width would make it
        // impossible to tell which widget was the right/bottom most.
        if (c.r() == edge.x)
            new_c.w = std::max(1, (this->x() + w) - c.x);
        if (c.b() == edge.y)
            new_c.h = std::max(1, (this->y() + h) - c.y);
        if (new_c != c) {
            DEBUG("c" << i << rect(child(i)) << " to " << new_c);
            this->child(i)->resize(new_c.x, new_c.y, new_c.w, new_c.h);
        }
    }
    if (Rect(x, y, w, h) != rect(this)) {
        Fl_Widget::resize(x, y, w, h);
        this->init_sizes();
    }
}


static void
set_cursor(Fl_Widget *widget, BoolPoint drag_state)
{
    static Fl_Cursor old_cursor;

    Fl_Cursor c;
    if (drag_state.x && drag_state.y)
        c = FL_CURSOR_MOVE;
    else if (drag_state.x)
        c = FL_CURSOR_WE;
    else if (drag_state.y)
        c = FL_CURSOR_NS;
    else
        c = FL_CURSOR_DEFAULT;

    if (c == old_cursor || !widget->window())
        return;
    old_cursor = c;
    widget->window()->cursor(old_cursor);
}


int
MoveTile::handle(int evt)
{
    static BoolPoint drag_state(false, false);
    static Point drag_from(0, 0);
    static int dragged_child = -1;

    Point mouse = mouse_pos();

    switch (evt) {
    case FL_MOVE: case FL_ENTER: case FL_PUSH:
        // return handle_move(evt, drag_state, drag_from);
        int r = this->handle_move(evt, &drag_state, &dragged_child);
        if (drag_state.x)
            drag_from.x = mouse.x;
        if (drag_state.y)
            drag_from.y = mouse.y;
        if (drag_state.x || drag_state.y)
            ASSERT(0 <= dragged_child && dragged_child < children());
        return r;

    case FL_LEAVE:
        drag_state = BoolPoint(false, false);
        set_cursor(this, drag_state);
        break;

    case FL_DRAG: case FL_RELEASE: {
        // I should only get these events if handle_move returned true, which
        // means am dragging.
        ASSERT(drag_state.x || drag_state.y);
        Point drag_to(drag_state.x ? mouse.x : 0, drag_state.y ? mouse.y : 0);
        this->handle_drag_tile(drag_from, drag_to, dragged_child);
        if (evt == FL_DRAG)
            this->set_changed(); // this means "changed value" to a callback
        else if (evt == FL_RELEASE)
            this->init_sizes();
        do_callback();
        return 1;
    }
    }
    return Fl_Group::handle(evt);
}


void
MoveTile::drag_tile(Point drag_from, Point drag_to)
{
    BoolPoint drag_state;
    int dragged_child = this->find_dragged_child(drag_from, &drag_state);
    this->handle_drag_tile(drag_from, drag_to, dragged_child);
    this->init_sizes();
}


void
MoveTile::set_stiff_child(int child)
{
    for (int i = this->stiff_children.size(); i < children(); i++) {
        this->stiff_children.push_back(false);
    }
    this->stiff_children[child] = true;
}


bool
MoveTile::stiff_child(int child)
{
    return child < this->stiff_children.size() && this->stiff_children[child];
}


// unpack the crazy Fl_Group::sizes() array
// 0 1 2 3 - x r y b
// obj, resize rect, child 0, child 1, ...
Rect
MoveTile::original_box(int child)
{
    const short *p = this->sizes();
    p += 8 + child*4;
    return Rect(p[0], p[2], p[1] - p[0], p[3] - p[2]);
}


// sort_children /////////////

static bool
child_wn_of(const Fl_Widget *c1, const Fl_Widget *c2)
{
    return c1->x() < c2->x() || c1->x() == c2->x() && c1->y() < c2->y();
}

// return indices of children going w->e, n->s
static const std::vector<int>
children_we_ns(Fl_Group *g)
{
    std::vector<Fl_Widget *> sorted(g->children());
    for (int i = 0; i < g->children(); i++)
        sorted[i] = g->child(i);
    std::sort(sorted.begin(), sorted.end(), child_wn_of);
    std::vector<int> indices(sorted.size());
    for (unsigned i = 0; i < sorted.size(); i++)
        indices[i] = g->find(sorted[i]);
    return indices;
}


bool
MoveTile::sort_children()
{
    bool moved = false;
    const std::vector<int> ordered = children_we_ns(this);
    for (int i = 0; i < ordered.size(); i++) {
        if (i != ordered[i]) {
            moved = true;
            this->insert(*this->child(i), i);
        }
    }
    return moved;
}



int
MoveTile::handle_move(int evt, BoolPoint *drag_state, int *dragged_child)
{
    *dragged_child = this->find_dragged_child(mouse_pos(), drag_state);
    // TODO Disable vertical drag for now.
    drag_state->y = false;
    set_cursor(this, *drag_state);
    // DEBUG("state: " << *drag_state << " drag_from: " << drag_from);
    if (drag_state->x || drag_state->y)
        return true; // I'm taking control now
    else
        return Fl_Group::handle(evt);
}


// Move neighbors to the right and down
// Doesn't actually resize any chidren, but modifies 'boxes' to the destination
// sizes and positions.
// drag_from is relative to the boxes in 'boxes'.
// dragged_child should be the upper left most dragged child.
static void
jostle(std::vector<Rect> &boxes, const Point &tile_edge,
        Point drag_from, Point drag_to, int dragged_child)
{
    DEBUG("jostle " << drag_from << " -> " << drag_to << " c" << dragged_child);
    Point shift(drag_to.x - drag_from.x, drag_to.y - drag_from.y);
    Rect dchild_box = boxes[dragged_child];
    int i = dragged_child;
    // Resize everyone lined up with the dragged child.
    for (; i < boxes.size() && boxes[i].r() == dchild_box.r(); i++) {
        DEBUG(i << " resize from " << boxes[i].w
                << " -> " << boxes[i].w + shift.x);
        boxes[i].w += shift.x;
    }

    // Continue to the right, pushing over children, except the rightmost
    // track, which gets resized, unless it's already as small as it can get,
    // in which case, push over.  The minimum size is 1, not 0, so the
    // order of the children is still clear.
    // TODO this is error prone, I can let it reach 0 if I go by the rightmost
    // xpos, not the rightmost r()
    Point edge(0, 0);
    for (int j = 0; j < boxes.size(); j++)
        edge.x = std::max(edge.x, boxes[j].r());
    for (; i < boxes.size(); i++) {
        Rect &c = boxes[i];
        // DEBUG("box to right at x " << c.x);
        // drag_from is relative to the original positions, not the current
        // dragged positions.
        if (c.r() < edge.x) {
            DEBUG(i << " move by " << shift << " from " << c.x << " to "
                    << c.x + shift.x);
            // This relies on dragged_child being the upper left most.
            c.x += shift.x;
        } else {
            int new_x = c.x + shift.x;
            int new_r = std::max(tile_edge.x, new_x+1);
            DEBUG(i << " outermost, (" << new_x << ", " << new_r << ")");
            c.x = new_x;
            c.w = new_r - new_x;
        }
        // TODO y drag
    }
}


// This drag always drags from the original box point and only resets the sizes
// on mouse up.  An alternate approach would reset the drag from on every
// event.  This would leave widgets where they are.
void
MoveTile::handle_drag_tile(const Point drag_from, const Point drag_to,
        int dragged_child)
{
    // DEBUG("drag tile from " << drag_from << " to " << drag_to);
    // drag_from is always the *original* from point, i.e. this is always an
    // absolute action.  That makes things easier here since otherwise
    // drag_from would be continually changing during a drag.  It also means
    // that widgets "remember" where they were as long as the mouse button is
    // down, which is possibly useful, possibly not.
    // A 0 in drag_from mean no movement there.
    // Also, respect this->minimum_size.
    // The right most / bottom most widget resizes instead of moving.
    std::vector<Rect> original_boxes(this->children());
    for (unsigned i = 0; i < children(); i++)
        original_boxes[i] = this->original_box(i);
    std::vector<Rect> boxes(original_boxes.begin(), original_boxes.end());

    /*
        if growing, jostle to right
        otherwise, for child in (from dragged to leftmost)
            jostle to min.x
    */
    Point shift(drag_to.x - drag_from.x, drag_to.y - drag_from.y);
    Point tile_edges(this->x() + this->w(), this->y() + this->h());
    // DEBUG("shift is " << shift);
    if (shift.x > 0) {
        // Going right is easy, just jostle over all children to the right.
        jostle(boxes, tile_edges, drag_from, drag_to, dragged_child);
        // Unless this is stiff, in which point I should go back to grow.
    } else {
        // Going left is harder, go back to the left trying to shrink children
        // until I have enough space.
        int shrinkage = -shift.x;
        for (int i = dragged_child; shrinkage > 0 && i >= 0; i--) {
            // I need to shrink by the upper left most, so if there is someone
            // before me at the same x, I should skip.
            if (i > 0 && boxes[i-1].x == boxes[i].x)
                continue;
            Rect child_box = boxes[i];
            int shrink_to = std::max(this->minimum_size.x,
                    child_box.w - shrinkage);
            // Stiff children never change size.
            if (this->stiff_child(i))
                shrink_to = child_box.w;
            DEBUG(i << show_widget(child(i)) << " shirk left " << shrinkage
                    << " from " << child_box.w << "->" << shrink_to);
            if (child_box.w > shrink_to) {
                jostle(boxes, tile_edges, Point(child_box.r(), 0),
                        Point(child_box.x + shrink_to, 0),
                        i);
                shrinkage -= child_box.w - shrink_to;
            }
        }
        ASSERT(shrinkage >= 0);
        DEBUG("shrink left " << shrinkage);
    }
    // TODO y drag

    for (unsigned i = 0; i < boxes.size(); i++) {
        const Rect r = boxes[i];
        // DEBUG(i << ": " << original_boxes[i] << " -> " << boxes[i]);
        this->child(i)->resize(r.x, r.y, r.w, r.h);
        this->child(i)->redraw();
    }
}


static int dist(int x, int y) { return abs(x-y); }

// Find the upper left most child from drag_from, if any, and return its
// index.  Also return dragging status into drag_state.  If 'drag_from'
// doesn't indicate any child, return -1 and drag_state is (false, false).
int
MoveTile::find_dragged_child(Point drag_from, BoolPoint *drag_state)
{
    // Edges on or outside the tile never get dragged.
    Rect tile_box = this->original_box(MoveTile::GROUP_SIZE);
    *drag_state = BoolPoint(false, false);
    for (int i = 0; i < this->children(); i++) {
        Rect box = rect(this->child(i));

        bool in_bounds = box.r() < tile_box.r();
        bool grabbable = dist(drag_from.x, box.r()) <= this->grab_area;
        bool inside = box.x <= drag_from.x && drag_from.x <= box.r();
        if (in_bounds && (grabbable || (this->stiff_child(i) && inside))) {
            drag_state->x = true;
            if (this->stiff_child(i))
                return this->previous_track(i);
            else
                return this->find(this->child(i));
        }
        // TODO y drag
    }
    return -1;
}


int
MoveTile::previous_track(int i) const
{
    int child_x = this->child(i)->x();
    while (i > 0 && this->child(i)->x() >= child_x)
        i--;
    // Found the one to the left, now find the uppermost one.
    child_x = this->child(i)->x();
    while (i > 0 && this->child(i)->x() == child_x)
        i--;
    return i;
}
