# Copyright 2010-2016 RethinkDB, all rights reserved.

# Rules for downloading and building dependencies
#
# These rules are governed by the settings generated from ./configure
# Such as the FETCH_LIST, *_VERSION, *_DEPENDS and *_DEP variables
#
# Some of these rules are complicated and delicate. They try to convince make to:
#  * not rebuild files that are already built
#  * not wait on files to be built when they are not needed yet
#
# To work around limitations of GNU make:
#  * if a target uses a pattern rule, it is never marked as phony
#  * pattern rules are used when a single recipe generates multiple targets
#  * all folder prerequisites are marked as order-only (using `|')
#  * rules are generated by macros that are expanded with `$(eval $(call ...))'
#  * inside macros, variables and function calls are escaped using `$$'

# How to call the pkg.sh script
WGET ?=
CURL ?=
JOBSERVER_FDS_FLAG = $(filter --jobserver-fds=%,$(MAKEFLAGS))
PKG_MAKEFLAGS = $(if $(JOBSERVER_FDS_FLAG), -j) $(JOBSERVER_FDS_FLAG)
PKG_SCRIPT_VARIABLES := WGET CURL NPM OS FETCH_LIST BUILD_ROOT_DIR PTHREAD_LIBS CROSS_COMPILING CXX CFLAGS CXXFLAGS LDFLAGS
PKG_SCRIPT = $(foreach v, $(PKG_SCRIPT_VARIABLES), $v='$($v)') MAKEFLAGS='$(PKG_MAKEFLAGS)' $/mk/support/pkg/pkg.sh
PKG_SCRIPT_TRACE = TRACE=1 $(PKG_SCRIPT)
PKG_RECURSIVE_MARKER := $(if $(findstring 0,$(JUST_SCAN_MAKEFILES)),$(if $(DRY_RUN),,+))

# How to log the output of fetching and building packages
ifneq (1,$(VERBOSE))
  $(shell mkdir -p $(SUPPORT_LOG_DIR))
  SUPPORT_LOG_REDIRECT = > $1 2>&1 || ( tail -n 20 $1 ; echo ; echo Full error log: $1 ; false )
else
  SUPPORT_LOG_REDIRECT :=
endif

# Phony targets to fetch and build all dependencies
.PHONY: fetch support
fetch: $(foreach pkg, $(FETCH_LIST), fetch-$(pkg))
support: $(foreach pkg, $(FETCH_LIST), support-$(pkg))

# Ignore old gtest files for backwards compatibility
$(SUPPORT_SRC_DIR)/gtest/%:
	true

# Download a dependency
$(SUPPORT_SRC_DIR)/%:
ifeq (1,$(ALWAYS_MAKE))
	$(warning Fetching $@ is disabled in --always-make (-B) mode)
else
	$P FETCH $*
	$(PKG_SCRIPT_TRACE) fetch $* $(call SUPPORT_LOG_REDIRECT, $(SUPPORT_LOG_DIR)/$*_fetch.log)
endif

# List of files that make expects the packages to install
SUPPORT_TARGET_FILES := $(foreach var, $(filter %_LIBS_DEP %_BIN_DEP, $(.VARIABLES)), $($(var)))
SUPPORT_INCLUDE_DIRS := $(foreach var, $(filter %_INCLUDE_DEP,        $(.VARIABLES)), $($(var)))

.PRECIOUS: $(SUPPORT_INCLUDE_DIRS)

# This function generates the suppport-* and fetch-* rules for each package
# $1 = target files, $2 = pkg name, $3 = pkg version
define support_rules

# Aliases for the longer version of these targets
.PHONY: fetch-$2 build-$2 clean-$2
fetch-$2: $(SUPPORT_SRC_DIR)/$2_$3
build-$2: build-$2_$3
clean-$2: clean-$2_$3

.PHONY: shrinkwrap-$2
shrinkwrap-$2:
	$(PKG_SCRIPT_TRACE) shrinkwrap $2_$3

# Depend on node for fetching node packages
$(SUPPORT_SRC_DIR)/$2_$3: | $(foreach dep, $(filter node,$($2_DEPENDS)), $(SUPPORT_BUILD_DIR)/$(dep)_$($(dep)_VERSION)/install.witness)

# Build a single package
.PHONY: support-$2 support-$2_$3
support-$2: support-$2_$3
support-$2_$3: $1

# Clean a single package
.PHONY: clean-$2_$3
clean-$2_$3:
	$$P RM $(SUPPORT_BUILD_DIR)/$2_$3
	rm -rf $(SUPPORT_BUILD_DIR)/$2_$3

# The actual rule that builds the package
# The targets are all modified to contain a `%' instead of the version number, otherwise make
# will re-run the recipe for each target.
# The generated prerequisites are:
#  * The directory containing the source code
#  * The include directories for this package, because some packages cannot run the install
#    and install-include rules in parallel
#  * The `install.witness' file for each of the dependencies of the package
build-$2_% $(foreach target,$1,$(subst _$3/,_%/,$(target))) $(SUPPORT_BUILD_DIR)/$2_%/install.witness: \
  | $(SUPPORT_SRC_DIR)/$2_$3 $(filter $(SUPPORT_BUILD_DIR)/$2_$3/include, $(SUPPORT_INCLUDE_DIRS)) \
  $(foreach dep, $($2_DEPENDS), $(SUPPORT_BUILD_DIR)/$(dep)_$($(dep)_VERSION)/install.witness)
ifeq (1,$(ALWAYS_MAKE))
	$$(warning Building $2_$3 is disabled in --always-make (-B) mode)
else
	$$P BUILD $2_$3
	$(PKG_RECURSIVE_MARKER)$$(PKG_SCRIPT_TRACE) install $2_$3 $$(call SUPPORT_LOG_REDIRECT, $$(SUPPORT_LOG_DIR)/$2_$3_install.log)
	touch $(SUPPORT_BUILD_DIR)/$2_$3/install.witness
endif

.PRECIOUS: $1 $(SUPPORT_BUILD_DIR)/$2_$3/install.witness

# Fetched packages need to be linked with flags that can only be
# guessed after the package has been installed.
ifneq (undefined,$$(origin $2_LIB_NAME))
  $$(foreach lib,$$($2_LIB_NAME),\
    $$(eval $$(lib)_LIBS = $$$$(shell $(PKG_SCRIPT) link-flags $2_$3 $$(lib))))
endif

endef

# For each package, list the target files and generate custom rules for that package
pkg_TARGET_FILES = $(filter $(SUPPORT_BUILD_DIR)/$(pkg)_%, $(SUPPORT_TARGET_FILES))
$(foreach pkg,$(FETCH_LIST),\
  $(eval $(call support_rules,$(pkg_TARGET_FILES),$(pkg),$($(pkg)_VERSION))))

# This function generates the support-include-* rules for a package
# $1 = include dir, $2 = pkg name, $3 = pkg version
define support_include_rules

# Install the include files for a given package
.PHONY: support-include-$2 support-include-$2_$3
.PRECIOUS: $3
install-include-$2: install-include-$2_$3
install-include-$2_% $(subst _$3/,_%/,$1): | $(SUPPORT_SRC_DIR)/$2_$3
ifeq (1,$(ALWAYS_MAKE))
	$$(warning Building $2_$3 is disabled in --always-make (-B) mode)
else
	$$P INSTALL-INCLUDE $2_$3
	$(PKG_RECURSIVE_MARKER)$$(PKG_SCRIPT_TRACE) install-include $2_$3 \
	  $$(call SUPPORT_LOG_REDIRECT, $$(SUPPORT_LOG_DIR)/$2_$3_install-include.log)
	test -e $1 && touch $1 || true
endif

endef

# List all the packages that have include files and generate custom rules for those files
include_PKG_NAME = $(word 1, $(subst _, $(space), $(patsubst $(SUPPORT_BUILD_DIR)/%, %, $(include))))
include_PKG_VERSION = $(word 2, $(subst _, $(space), $(subst /, $(space), $(patsubst $(SUPPORT_BUILD_DIR)/%, %, $(include)))))
$(foreach include, $(SUPPORT_INCLUDE_DIRS), \
  $(eval $(call support_include_rules,$(include),$(include_PKG_NAME),$(include_PKG_VERSION))))
