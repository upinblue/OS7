using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace OS7.App.SoftwareUpdate.ViewModels;

/// <summary>
/// The smallest possible <see cref="INotifyPropertyChanged"/>.
/// </summary>
/// <remarks>
/// Deliberately not CommunityToolkit.Mvvm. The measured cost of this
/// application is 22.1 MiB and every megabyte of it is argued for in
/// docs/SESSION-AVALONIA-FOOTPRINT.md; a source generator and a runtime package
/// to avoid writing this file twice is not an argument that survives that.
/// </remarks>
public abstract class ViewModelBase : INotifyPropertyChanged
{
	public event PropertyChangedEventHandler? PropertyChanged;

	protected void Raise([CallerMemberName] string? name = null) =>
		PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

	protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
	{
		if (EqualityComparer<T>.Default.Equals(field, value))
		{
			return false;
		}

		field = value;
		Raise(name);
		return true;
	}
}
