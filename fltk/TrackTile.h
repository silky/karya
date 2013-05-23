/* This adds track-specific stuff to a MoveTile.

    Manage the underlying MoveTile:
    Fill rightmost track edge until the right edge of the window with a pad box
    of the given color.

    Accept zoom callbacks from parent Zoom and BlockView.

    Tracks come in pairs of a title and body.

    TrackTile________________
       |           \         \
    title_input  EventTrack  SeqInput (edit_input, temporary)
*/

#ifndef __TRACK_TILE_H
#define __TRACK_TILE_H

#include <math.h>

#include <FL/Fl_Box.H>

#include "util.h"
#include "f_util.h"

#include "MoveTile.h"
#include "Track.h"
#include "SeqInput.h"


class TrackTile : public MoveTile {
public:
    TrackTile(int X, int Y, int W, int H, Color bg_color, int title_height);
    virtual int handle(int evt);

    void set_bg_color(Color c) {
        track_pad.color(color_to_fl(c));
        track_pad.redraw();
    }
    void set_zoom(const ZoomInfo &zoom);
    void set_title_height(int title_height) {
        this->title_height = title_height;
        this->update_sizes();
        this->redraw();
    }

    // Edit input.
    void edit_open(int tracknum, ScoreTime pos, const char *text,
        int select_start, int select_end);
    void edit_close();
    void edit_append(const char *text);

    // ScoreTime of the end of the last event.
    ScoreTime time_end() const;
    // ScoreTime of the bottom of the visible window.
    ScoreTime view_end() const;
    // Visible amount of track.
    ScoreTime visible_time() const;
    // Right side of the rightmost track.
    int track_end() const;
    // Visible width and height.
    IPoint visible_pixels() const;

    void insert_track(int tracknum, TrackView *track, int width);
    // Remove and return the TrackView, so the parent can delete it.
    TrackView *remove_track(int tracknum);
    // A track is a (title, body) pair, minus the track_pad.
    int tracks() const {
        return floor((children() - (edit_input ? 1 : 0)) / 2.0);
    }
    TrackView *track_at(int tracknum);
    const TrackView *track_at(int tracknum) const;
    int get_track_width(int tracknum) const;
    void set_track_width(int tracknum, int width);

    // Return the track currently being dragged right now, or -1.
    int get_dragged_track() const;

protected:
    virtual void draw();
private:
    int title_height;
    ZoomInfo zoom;
    Fl_Box track_pad; // box to take up space not covered by tracks
    // Created and destroyed when 'edit_open' is called.
    SeqInput *edit_input;

    void update_sizes();
};

#endif
