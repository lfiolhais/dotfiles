function zip --wraps zip --description "zip, never storing a .git directory"
    # -x takes every following non-option argument as an exclude pattern, so it
    # has to come after the archive name and the files rather than before them:
    # `zip -x '*/.git/*' out.zip dir` reads out.zip and dir as two more patterns
    # and leaves zip with nothing to archive.
    #
    # Two patterns rather than one substring: '*/.git/*' catches a repository
    # nested under the directory being archived, including a submodule's, and
    # '.git/*' the one at the top when the archive is made from inside the
    # checkout. Both match the directory entry as well as its contents, since
    # zip's `*` matches the empty string. The substring '*.git*' would be
    # shorter and would also drop .gitignore, .gitmodules and the whole
    # .github/ tree, so an archive handed to someone else would arrive with no
    # CI workflows and zip would say nothing about it.
    command zip $argv -x '*/.git/*' '.git/*'
end
