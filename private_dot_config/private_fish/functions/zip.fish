function zip --wraps zip --description "zip, dropping every name containing .git"
    # -x takes every following non-option argument as an exclude pattern, so it
    # has to come after the archive name and the files rather than before them:
    # `zip -x '*.git*' out.zip dir` reads out.zip and dir as two more patterns
    # and leaves zip with nothing to archive.
    # '*.git*' is a substring match, so .gitignore, .gitmodules and .github/
    # go too, not only .git/.
    command zip $argv -x '*.git*'
end
