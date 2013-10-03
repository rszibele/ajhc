#!/usr/bin/env sh
wget "http://lambda.haskell.org/platform/download/2013.2.0.0/Haskell Platform 2013.2.0.0 32bit.pkg"
sudo installer -pkg "Haskell Platform 2013.2.0.0 32bit.pkg" -target /
brew update
brew install valgrind
echo "yes" | sudo cpan install YAML
cabal update || cabal update
export HSPACKS="derive temporary haskeline utf8-string HsSyck cpphs test-framework-th test-framework-hunit test-framework-quickcheck2 uniplate"
export HSOPTS="--disable-documentation --disable-library-profiling --disable-executable-profiling"
cabal install $HSOPTS $HSPACKS || cabal install $HSOPTS $HSPACKS
