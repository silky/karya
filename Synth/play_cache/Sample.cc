// Copyright 2018 Evan Laforge
// This program is distributed under the terms of the GNU General Public
// License 3.0, see COPYING or http://www.gnu.org/licenses/gpl-3.0.txt

#include <algorithm>
#include <cstring>
#include <dirent.h>
#include <ostream>
#include <sstream>
#include <vector>

#include "Sample.h"
#include "Synth/Shared/config.h"
#include "log.h"

using std::string;


// util


static bool
ends_with(const string &str, const string &suffix)
{
    return str.compare(
            str.length() - std::min(str.length(), suffix.length()),
            string::npos,
            suffix
        ) == 0;
}


static bool
is_sample(const string &str)
{
    // Don't try to load random junk, e.g. reaper .repeaks files.
    // I write .debug.wav for debugging.
    return ends_with(str, ".wav") && !ends_with(str, ".debug.wav");
}


static std::vector<string>
list_samples(std::ostream &log, const string &dir)
{
    struct dirent *ent;
    std::vector<string> fnames;
    DIR *d = opendir(dir.c_str());
    if (!d) {
        LOG("list_samples: not a dir: " << dir);
        return fnames;
    }
    while ((ent = readdir(d)) != nullptr) {
        if (ent->d_type != DT_REG && ent->d_type != DT_LNK)
            continue;
        string fname(ent->d_name);
        if (is_sample(fname))
            fnames.push_back(fname);
    }
    if (closedir(d) == -1) {
        LOG("closing " << dir << ": " << strerror(errno));
    }
    std::sort(fnames.begin(), fnames.end());
    return fnames;
}


static string
find_nth_sample(std::ostream &log, const string &dir, int n)
{
    std::vector<string> fnames = list_samples(log, dir);
    return n < fnames.size() ? fnames[n] : "";
}


static string
find_next_sample(std::ostream &log, const string &dir, const string &fname)
{
    std::vector<string> fnames = list_samples(log, dir);
    const auto next = std::find_if(
        fnames.begin(), fnames.end(),
        [&](const string &s) { return s > fname; });
    return next == fnames.end() ?  "" : *next;
}


// Open the file at the given offset.  Return nullptr if there was an error,
// or the offset is past the end of the file.
static Wav *
open_sample(
    std::ostream &log, int channels, bool one_channel_ok, int sample_rate,
    const string &fname, Frames offset, int *file_channels)
{
    Wav *wav;
    Wav::Error err = Wav::open(fname.c_str(), &wav, offset);
    if (err) {
        LOG(fname << ": " << err);
        return nullptr;
    }
    if (!(wav->channels() == channels
        || (one_channel_ok && wav->channels() == 1)))
    {
        LOG(fname << ": expected " << channels << " channels, got "
            << wav->channels());
    } else if (wav->srate() != sample_rate) {
        LOG(fname << ": expected srate of " << sample_rate << ", got "
            << wav->srate());
    } else {
        if (file_channels)
            *file_channels = wav->channels();
        // I used to check if I had seeked off the end of the sample, or if
        // it's a silent block (0 frames, emitted by
        // Audio.File.writeCheckpoints), and if so close it right here.  But
        // it's simpler to not expose frames_remaining and let read() run out
        // when it runs out.
        return wav;
    }
    delete wav;
    return nullptr;
}

// SampleDirectory

SampleDirectory::SampleDirectory(
        std::ostream &log, int channels, int sample_rate,
        const string &dir, Frames offset) :
    log(log), sample_rate(sample_rate), dir(dir), wav(nullptr),
    frames_left(0)
{
    int filenum = offset / (CHUNK_SECONDS * sample_rate);
    this->fname = find_nth_sample(log, dir, filenum);
    Frames file_offset = offset % (CHUNK_SECONDS * sample_rate);
    LOG("dir " << dir << ": start at '" << fname << "' + " << file_offset);
    if (!fname.empty()) {
        this->open(channels, file_offset);
    }
}


SampleDirectory::~SampleDirectory()
{
    if (wav)
        delete wav;
}


bool
SampleDirectory::read(int channels, Frames frames, float **out)
{
    buffer.resize(frames * channels);
    Frames total_read = 0;
    while (!fname.empty() && frames - total_read > 0) {
        const Frames offset = total_read * channels;
        Frames delta;
        if (wav == nullptr) {
            // File is a silent chunk or otherwise ended early.
            if (frames_left > 0) {
                delta = std::min(frames_left, frames - total_read);
                frames_left -= delta;
                // I could possibly notice when it's all 0 and avoid the work
                // and the mixing, but memset 0 should be fast, and mixing is
                // pretty trivial too.
                std::fill(
                    buffer.begin() + offset,
                    buffer.begin() + offset + delta,
                    0);
            } else {
                break;
            }
        } else {
            // TODO read could fail, handle that
            delta = wav->read(buffer.data() + offset, frames - total_read);
            // delta could be > frames_left if a chunk > CHUNK_SECONDS, which
            // shouldn't happen.  But if it does, the rest will be offset,
            // which hopefully I'll notice.
            frames_left -= std::min(frames_left, delta);
            if (delta < frames - total_read) {
                // Short read, this file is done.
                delete wav;
                wav = nullptr;
            }
        }
        if (frames_left == 0) {
            fname = find_next_sample(log, dir, fname);
            this->open(channels, 0);
            LOG(dir << ": next sample: " << (fname.empty() ? "<done>" : fname));
        }
        total_read += delta;
    };
    std::fill(buffer.begin() + total_read * channels, buffer.end(), 0);
    *out = buffer.data();
    return total_read == 0;
}


void
SampleDirectory::open(int channels, Frames offset)
{
    if (wav)
        delete wav;
    if (!fname.empty()) {
        wav = open_sample(
            log, channels, false, sample_rate, dir + '/' + fname, offset,
            nullptr);
        // offset should never be > chunk frames.
        this->frames_left = CHUNK_SECONDS * sample_rate - offset;
    }
}


// SampleFile

SampleFile::SampleFile(
        std::ostream &log, int channels, bool expand_channels, int sample_rate,
        const string &fname, Frames offset) :
    log(log), expand_channels(expand_channels), fname(fname), wav(nullptr),
    file_channels(0)
{
    if (!fname.empty()) {
        LOG(fname << " + " << offset);
        wav = open_sample(
            log, channels, expand_channels, sample_rate, fname, offset,
            &this->file_channels);
    }
}


SampleFile::~SampleFile()
{
    if (wav)
        delete wav;
}


bool
SampleFile::read(int channels, Frames frames, float **out)
{
    if (wav == nullptr) {
        return true;
    }
    buffer.resize(frames * channels);
    Frames read;
    if (expand_channels && file_channels == 1 && channels != 1) {
        expand_buffer.resize(frames);
        read = wav->read(expand_buffer.data(), frames);
        for (Frames f = 0; f < read; f++) {
            for (int c = 0; c < channels; c++) {
                buffer[f*channels + c] = expand_buffer[f];
            }
        }
    } else {
        read = wav->read(buffer.data(), frames);
    }
    // Wav::read only reads less than asked if the file ended.
    if (read < frames) {
        delete wav;
        wav = nullptr;
    }
    std::fill(buffer.begin() + read * channels, buffer.end(), 0);
    *out = buffer.data();
    return read == 0;
}
