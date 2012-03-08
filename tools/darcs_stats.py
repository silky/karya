#!/usr/bin/env python
import sys, subprocess, re, os

def main():
    p = subprocess.Popen(['darcs', 'whatsnew', '-l'] + sys.argv[1:],
        stdout=subprocess.PIPE)
    stdout, _ = p.communicate()
    adds, subtracts = parse_whatsnew(stdout.split('\n'))

    normal_by_dir = {}
    test_by_dir = {}
    for path in set(adds).union(set(subtracts)):
        if path.endswith('_test.hs'):
            by_dir = test_by_dir
        else:
            by_dir = normal_by_dir
        dir = os.path.dirname(path) or '.'
        add, subtract = by_dir.get(dir, (0, 0))
        by_dir[dir] = (adds.get(path, 0) + add,
            subtracts.get(path, 0) + subtract)

    longest = max(map(len, normal_by_dir.keys() + test_by_dir.keys()))
    col1 = 16
    print '%-*s %-*s test' % (longest, 'dir', col1, 'normal')
    for dir in sorted(set(normal_by_dir).union(set(test_by_dir))):
        normal = normal_by_dir.get(dir, (0, 0))
        test = test_by_dir.get(dir, (0, 0))
        print '%-*s %-*s %s' % (
            longest, dir, col1, show_diff(normal), show_diff(test))
    print
    print '%-*s %-*s %s' % (longest, 'total', col1,
        show_diff(sum_diffs(normal_by_dir.values())),
        show_diff(sum_diffs(test_by_dir.values())))

def sum_diffs(diffs):
    return (sum(map(fst, diffs)), sum(map(snd, diffs)))

def show_diff((add, sub)):
    return '+%d-%d %d' % (add, abs(sub), add+sub)

def parse_whatsnew(lines):
    adds = {}
    subtracts = {}
    for line in lines:
        m = re.match(r'[MA] ([./a-zA-Z_-]+) *(\-\d+)? *(\+\d+)?$', line)
        if not m:
            if m and m[0] in 'MA':
                print 'no match', repr(line)
            continue
        path = os.path.normpath(m.groups()[0])
        if path == 'TODO':
            continue # not actually code changes
        dir = os.path.dirname(path) or '.'

        if line.startswith('A'):
            # darcs doesn't show lines for new files
            if not os.path.isdir(path):
                adds[path] = len(list(open(path)))
        else:
            for diff in filter(None, m.groups()[1:]):
                if diff.startswith('-'):
                    subtracts[path] = int(diff)
                elif diff.startswith('+'):
                    adds[path] = int(diff)
    return adds, subtracts

def fst((a, b)): return a
def snd((a, b)): return b

if __name__ == '__main__':
    main()

