# Script to set up Miniconda with a test environment

# This script has been heavily adapted from a script by Olivier Grisel and Kyle
# Kastner licensed under a BSD 3-clause license, and subsequently modified by
# Stuart Mumford before being adapted to its current form in ci-helper.

# We use the following function to exit the script after any failing command
function checkLastExitCode {
  if ($lastExitCode) {
    echo "ERROR: the last command returned the following exit code: $lastExitCode"
    Exit $lastExitCode
  }
}

$QUIET = "-q"

if ($env:DEBUG) {
    if($env:DEBUG -match "True") {

        # Show all commands
        Set-PSDebug -Trace 1

        # Print out environment variables
        Get-ChildItem Env:

        # Disable Quiet mode
        $QUIET = ""

    }
}

$MINICONDA_URL = "https://repo.continuum.io/miniconda/"

# We will use the 2.0.x releases as "stable" for Python 2.7 and 3.4
if ((python -c "from distutils.version import LooseVersion; import os; print(LooseVersion(os.environ['PYTHON_VERSION']) < str(3.5))") -match "False") {
    $env:LATEST_ASTROPY_STABLE = "3.0"
}
else {
    $env:LATEST_ASTROPY_STABLE = "2.0.4"
}

$env:ASTROPY_LTS_VERSION = "2.0.4"
$env:LATEST_NUMPY_STABLE = "1.14"
$env:LATEST_SUNPY_STABLE = "0.8.3"

# We pin the version for conda as it's not the most stable package from
# release to release. Add note here if version is pinned due to a bug upstream.
if (! $env:CONDA_VERSION) {
   $env:CONDA_VERSION = "4.3.27"
}

if (! $env:PIP_FALLBACK) {
   $env:PIP_FALLBACK = "True"
}

function DownloadMiniconda ($version, $platform_suffix) {
    $webclient = New-Object System.Net.WebClient
    $filename = "Miniconda3-" + $version + "-Windows-" + $platform_suffix + ".exe"

    $url = $MINICONDA_URL + $filename

    $basedir = $pwd.Path + "\"
    $filepath = $basedir + $filename
    if (Test-Path $filename) {
        Write-Host "Reusing" $filepath
        return $filepath
    }

    # Download and retry up to 3 times in case of network transient errors.
    Write-Host "Downloading" $filename "from" $url
    $retry_attempts = 2
    for($i=0; $i -lt $retry_attempts; $i++){
        try {
            $webclient.DownloadFile($url, $filepath)
            break
        }
        Catch [Exception]{
            Start-Sleep 1
        }
   }
   if (Test-Path $filepath) {
       Write-Host "File saved at" $filepath
   } else {
       # Retry once to get the error message if any at the last try
       $webclient.DownloadFile($url, $filepath)
   }
   return $filepath
}

function InstallMiniconda ($miniconda_version, $architecture, $python_home) {
    Write-Host "Installing miniconda" $miniconda_version "for" $architecture "bit architecture to" $python_home
    if (Test-Path $python_home) {
        Write-Host $python_home "already exists, skipping."
        return $false
    }
    if ($architecture -eq "x86") {
        $platform_suffix = "x86"
    } else {
        $platform_suffix = "x86_64"
    }
    $filepath = DownloadMiniconda $miniconda_version $platform_suffix
    Write-Host "Installing" $filepath "to" $python_home
    $args = "/InstallationType=AllUsers /S /AddToPath=1 /RegisterPython=1 /D=" + $python_home
    Write-Host $filepath $args
    Start-Process -FilePath $filepath -ArgumentList $args -Wait -Passthru
    #Start-Sleep -s 15
    if (Test-Path $python_home) {
        Write-Host "Miniconda $miniconda_version ($architecture) installation complete"
    } else {
        Write-Host "Failed to install Python in $python_home"
        Exit 1
    }
}

# Install miniconda, if no version is given use the latest
if (! $env:MINICONDA_VERSION) {
   $env:MINICONDA_VERSION="latest"
}

InstallMiniconda $env:MINICONDA_VERSION $env:PLATFORM $env:PYTHON
checkLastExitCode

# Set environment variables
$env:PATH = "${env:PYTHON};${env:PYTHON}\Scripts;" + $env:PATH

# Conda config

conda config --set always_yes true
checkLastExitCode

conda config --add channels defaults
checkLastExitCode

if ($env:CONDA_CHANNELS) {
   $CONDA_CHANNELS=$env:CONDA_CHANNELS.split(" ")
   foreach ($CONDA_CHANNEL in $CONDA_CHANNELS) {
       conda config --add channels $CONDA_CHANNEL
       checkLastExitCode
   }
   Remove-Variable CONDA_CHANNELS
   rm env:CONDA_CHANNELS
}

# Install the build and runtime dependencies of the project.
conda install $QUIET conda=$env:CONDA_VERSION
checkLastExitCode

if (! $env:CONDA_CHANNEL_PRIORITY) {
   $CONDA_CHANNEL_PRIORITY="false"
} else {
   $CONDA_CHANNEL_PRIORITY=$env:CONDA_CHANNEL_PRIORITY.ToLower()
}

# We need to add this after the update, otherwise the ``channel_priority``
# key may not yet exists
conda config  --set channel_priority $CONDA_CHANNEL_PRIORITY
checkLastExitCode

# Create a conda environment using the astropy bonus packages
if (! $env:CONDA_ENVIRONMENT ) {
   conda create $QUIET -n test python=$env:PYTHON_VERSION
} else {
   conda env create $QUIET -n test -f $env:CONDA_ENVIRONMENT
}
checkLastExitCode

activate test
checkLastExitCode

# Set environment variables for environment (activate test doesn't seem to do the trick)
$env:PATH = "${env:PYTHON}\envs\test;${env:PYTHON}\envs\test\Scripts;${env:PYTHON}\envs\test\Library\bin;" + $env:PATH

# Check that we have the expected version of Python
python --version
checkLastExitCode

# CORE DEPENDENCIES
# any pinned version should be set in `pinned`
Copy-Item ci-helpers\appveyor\pinned ${env:PYTHON}\envs\test\conda-meta\pinned

conda install $QUIET -n test pytest pip
checkLastExitCode

# Check whether a specific version of Numpy is required
if ($env:NUMPY_VERSION) {
    if($env:NUMPY_VERSION -match "stable") {
        $NUMPY_OPTION = "numpy=" + $env:LATEST_NUMPY_STABLE
    } elseif($env:NUMPY_VERSION -match "dev") {
        $NUMPY_OPTION = "Cython pip".Split(" ")
    } else {
        $NUMPY_OPTION = "numpy=" + $env:NUMPY_VERSION
    }
    conda install -n test $QUIET $NUMPY_OPTION
    checkLastExitCode
} else {
    $NUMPY_OPTION = ""
}

# Check whether a specific version of Astropy is required
if ($env:ASTROPY_VERSION) {
    if($env:ASTROPY_VERSION -match "stable") {
        $ASTROPY_OPTION = "astropy=" + $env:LATEST_ASTROPY_STABLE
    } elseif($env:ASTROPY_VERSION -match "dev") {
        $ASTROPY_OPTION = "Cython pip jinja2".Split(" ")
    } elseif($env:ASTROPY_VERSION -match "lts") {
        $ASTROPY_OPTION = "astropy=" + $env:ASTROPY_LTS_VERSION
    } else {
        $ASTROPY_OPTION = "astropy=" + $env:ASTROPY_VERSION
    }
    $output = cmd /c conda install -n test $QUIET $NUMPY_OPTION $ASTROPY_OPTION 2>&1
    echo $output
    if (($output | select-string UnsatisfiableError) -and $env:PIP_FALLBACK) {
       echo "Installing astropy with conda was unsuccessful, using pip instead"
       pip install $ASTROPY_OPTION
       checkLastExitCode
    } else {
      checkLastExitCode
    }
} else {
    $ASTROPY_OPTION = ""
}

# Check whether a specific version of Sunpy is required
if ($env:SUNPY_VERSION) {
    if($env:SUNPY_VERSION -match "stable") {
        $SUNPY_OPTION = "sunpy"
    } elseif($env:SUNPY_VERSION -match "dev") {
        $SUNPY_OPTION = ""
    } else {
        $SUNPY_OPTION = "sunpy=" + $env:SUNPY_VERSION
    }
    $output = cmd /c conda install -n test $QUIET $NUMPY_OPTION $SUNPY_OPTION 2>&1
    echo $output
    if (($output | select-string UnsatisfiableError) -and $env:PIP_FALLBACK) {
       echo "Installing sunpy with conda was unsuccessful, using pip instead"
       pip install $SUNPY_OPTION
       checkLastExitCode
    } else {
      checkLastExitCode
    }
} else {
    $SUNPY_OPTION = ""
}

# Install the specified versions of numpy and other dependencies
if ($env:CONDA_DEPENDENCIES) {
    $CONDA_DEPENDENCIES = $env:CONDA_DEPENDENCIES.split(" ")
} else {
    $CONDA_DEPENDENCIES = ""
}

# If NUMPY_OPTION and CONDA_DEPENDENCIES are both empty, we skip this step
if ($NUMPY_OPTION -or $CONDA_DEPENDENCIES) {

  $output = cmd /c conda install -n test $QUIET $NUMPY_OPTION $CONDA_DEPENDENCIES 2>&1
  echo $output
  if (($output | select-string UnsatisfiableError, PackageNotFoundError) -and $env:PIP_FALLBACK) {
     echo "Installing dependencies with conda was unsuccessful, using pip instead"
     $output = cmd /c pip install $CONDA_DEPENDENCIES 2>&1
     echo $output
     checkLastExitCode
     if ($output | select-string UnsatisfiableError, PackageNotFoundError) {
        Exit 1
     }
  } else {
    checkLastExitCode
  }

}

# Check whether the developer version of Numpy is required and if yes install it
if ($env:NUMPY_VERSION -match "dev") {
   Invoke-Expression "${env:CMD_IN_ENV} pip install git+https://github.com/numpy/numpy.git#egg=numpy --upgrade --no-deps"
   checkLastExitCode
}

# Check whether the developer version of Astropy is required and if yes install
# it. We need to include --no-deps to make sure that Numpy doesn't get upgraded.
if ($env:ASTROPY_VERSION -match "dev") {
   Invoke-Expression "${env:CMD_IN_ENV} pip install pytest-astropy"
   Invoke-Expression "${env:CMD_IN_ENV} pip install git+https://github.com/astropy/astropy.git#egg=astropy --upgrade --no-deps"
   checkLastExitCode
}

# Check whether the developer version of Sunpy is required and if yes install
# it. We need to include --no-deps to make sure that Numpy doesn't get upgraded.
if ($env:SUNPY_VERSION -match "dev") {
   Invoke-Expression "${env:CMD_IN_ENV} pip install git+https://github.com/sunpy/sunpy.git#egg=sunpy --upgrade --no-deps"
   checkLastExitCode
}

# We finally install the dependencies listed in PIP_DEPENDENCIES. We do this
# after installing the Numpy versions of Numpy or Astropy. If we didn't do this,
# then calling pip earlier could result in the stable version of astropy getting
# installed, and then overritten later by the dev version (which would waste
# build time)

if ($env:PIP_FLAGS) {
    $PIP_FLAGS = $env:PIP_FLAGS.split(" ")
} else {
    $PIP_FLAGS = ""
}

if ($env:PIP_DEPENDENCIES) {
    $PIP_DEPENDENCIES = $env:PIP_DEPENDENCIES.split(" ")
} else {
    $PIP_DEPENDENCIES = ""
}

if ($env:PIP_DEPENDENCIES) {
    pip install $PIP_DEPENDENCIES $PIP_FLAGS
    checkLastExitCode
}
